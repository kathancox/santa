/// Copyright 2021 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "Source/santad/Logs/SNTSimpleMaildir.h"

#include <mach/mach_time.h>
#include <malloc/malloc.h>
#include <stdio.h>

#import "Source/common/SNTLogging.h"
#import "Source/common/SNTMetricSet.h"

static NSString *kDefaultMetricFieldName = @"result";
static NSString *kErrorUserInfoKey = @"MetricsFieldName";

/** Helper for creating errors. */
static NSError *MakeError(NSString *description) {
  return [NSError errorWithDomain:@"com.google.santa"
                             code:1
                         userInfo:@{kErrorUserInfoKey : description}];
}

static NSString *ErrorToMetricFieldName(NSError *error) {
  if (!error) {
    return kDefaultMetricFieldName;
  }

  return error.userInfo[kErrorUserInfoKey]
           ?: [NSString stringWithFormat:@"%@:%d", error.domain, (int)error.code];
}

static size_t SNTRoundUpToNextPage(size_t size) {
  const size_t pageSize = 4096;

  if (size % pageSize == 0) {
    return size;
  }
  return pageSize * ((size / pageSize) + 1);
}

static uint64_t getUptimeSeconds() {
  static dispatch_once_t onceToken;
  static mach_timebase_info_data_t info;

  dispatch_once(&onceToken, ^{
    mach_timebase_info(&info);
  });

  uint64_t cur = mach_absolute_time();

  // Convert from nanoseconds to seconds
  return cur * info.numer / (1000 * 1000 * 1000 * info.denom);
}

NS_ASSUME_NONNULL_BEGIN

@implementation SNTSimpleMaildir {
  /** The prefix to use for new log files. */
  NSString *_filenamePrefix;

  /** The base, tmp and new directory for spooling files. */
  NSString *_baseDirectory;
  NSString *_tmpDirectory;
  NSString *_newDirectory;

  /**
   * Timer that flushes every `maxTimeBetweenFlushes` seconds.
   * Used to avoid excessive latency exporting events.
   */
  NSTimer *_flushTimer;

  /** The size threshold after which to start a new log file. */
  size_t _fileSizeThreshold;

  /** Threshold for the estimated spool size. */
  size_t _spoolSizeThreshold;

  /** Temporary storage for SNTPBSantaMessage in an SNTPBLogBatch. */
  SNTPBLogBatch *_outputProto;

  /** Current serialized size of all events in the _outputProto batch */
  size_t _outputProtoSerializedSize;

  /** Current size of the file system spooling directory. */
  size_t _estimatedSpoolSize;

  /** Counter for the files we've already opened. Used to generate file names. */
  int _createdFileCount;

  /** Dispatch queue to synchronize flush operations */
  dispatch_queue_t _flushQueue;

  /** Counter for successful and failed event flushing to disk. */
  SNTMetricCounter *_eventsFlushedCounter;

  /** Counter for successful and failed event queueing in memory. */
  SNTMetricCounter *_eventsQueuedCounter;

  /** Gauge for the overall spool size, calculated periodically. */
  SNTMetricInt64Gauge *_spoolSizeGauge;

  /**
   * Mach absolute time in seconds of the last time the spool size
   * was calculated.
   */
  uint64_t _lastCalculatedSpoolSizeTime;
}

- (instancetype)initWithBaseDirectory:(NSString *)baseDirectory
                       filenamePrefix:(NSString *)filenamePrefix
                    fileSizeThreshold:(size_t)fileSizeThreshold
               directorySizeThreshold:(size_t)directorySizeThreshold
                maxTimeBetweenFlushes:(NSTimeInterval)maxTimeBetweenFlushes {
  self = [super init];
  if (self) {
    _baseDirectory = baseDirectory;
    _tmpDirectory = [baseDirectory stringByAppendingPathComponent:@"tmp"];
    _newDirectory = [baseDirectory stringByAppendingPathComponent:@"new"];
    _filenamePrefix = [filenamePrefix copy];
    _fileSizeThreshold = fileSizeThreshold;
    _spoolSizeThreshold = directorySizeThreshold;
    _estimatedSpoolSize = SIZE_T_MAX;  // Force a recalculation of the spool directory size
    _createdFileCount = 0;
    _outputProto = [[SNTPBLogBatch alloc] init];
    _outputProtoSerializedSize = 0;
    _lastCalculatedSpoolSizeTime = 0;

    _eventsFlushedCounter = [[SNTMetricSet sharedInstance]
      counterWithName:@"/santa/events_flushed"
           fieldNames:@[ kDefaultMetricFieldName ]
             helpText:@"Number of events flushed, with the result of the flush operation"];
    _eventsQueuedCounter = [[SNTMetricSet sharedInstance]
      counterWithName:@"/santa/events_queued"
           fieldNames:@[ kDefaultMetricFieldName ]
             helpText:@"Number of events queued in memory, with the result "
                      @"of their conversion to anyproto"];
    _spoolSizeGauge =
      [[SNTMetricSet sharedInstance] int64GaugeWithName:@"/santa/spool_size"
                                             fieldNames:@[ kDefaultMetricFieldName ]
                                               helpText:@"Snapshot of the current pool size"];

    [[SNTMetricSet sharedInstance] registerCallback:^(void) {
      // Only calculate spool size for metrics every 5 minutes
      static const int frequencySecs = 300;

      uint64_t curTime = getUptimeSeconds();

      if (curTime - _lastCalculatedSpoolSizeTime >= frequencySecs) {
        NSError *err = nil;
        size_t curSize = [SNTSimpleMaildir spoolDirectorySize:_newDirectory withError:&err];

        if (err) {
          // Failed to calculate spool size. Try again next time...
          return;
        }

        _lastCalculatedSpoolSizeTime = curTime;

        [_spoolSizeGauge set:curSize forFieldValues:@[ kDefaultMetricFieldName ]];
      }
    }];

    _flushQueue =
      dispatch_queue_create("com.google.santa.daemon.mail",
                            dispatch_queue_attr_make_with_qos_class(
                              DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL, QOS_CLASS_DEFAULT, 0));

    typeof(self) __weak weakSelf = self;
    _flushTimer = [NSTimer scheduledTimerWithTimeInterval:maxTimeBetweenFlushes
                                                  repeats:YES
                                                    block:^(NSTimer *_Nonnull timer) {
                                                      [weakSelf flush];
                                                    }];
  }
  return self;
}

- (void)dealloc {
  [_flushTimer invalidate];
  [self flush];
}

/** Fires the flush timer programmatically. Used for testing purposes. */
- (void)fireFlushTimer {
  [_flushTimer fire];
}

/**
 * Flushes out buffered data.
 *
 * Returns the number of events that we attempted to flush, and populates the error if that flush
 * failed.
 */
- (void)flushLockedWithError:(NSError **)error {
  NSAssert([_outputProto.recordsArray count] < INT_MAX, @"Too many records");

  if ([_outputProto.recordsArray count] == 0) {
    return;
  }

  if (![self createSpoolDirectoriesWithError:error]) {
    return;
  }

  if (_estimatedSpoolSize > _spoolSizeThreshold) {
    _estimatedSpoolSize = [SNTSimpleMaildir spoolDirectorySize:_newDirectory withError:error];
    if (_estimatedSpoolSize > _spoolSizeThreshold) {
      if (error) {
        *error = MakeError(@"file_system_threshold_exceeded");
      }
      return;
    }
  }

  NSString *filename = [NSString stringWithFormat:@"%@.%u", _filenamePrefix, _createdFileCount];
  NSString *exposedFilepath = [_newDirectory stringByAppendingPathComponent:filename];
  NSString *outputFilepath = [_tmpDirectory stringByAppendingPathComponent:filename];
  NSOutputStream *outputFile = [NSOutputStream outputStreamToFileAtPath:outputFilepath append:NO];
  [outputFile open];
  _createdFileCount++;

  if (!outputFile) {
    if (error) {
      *error = MakeError(@"data_loss_on_open");
    }
    return;
  }

  BOOL writeSuccess = NO;
  @try {
    [_outputProto writeToOutputStream:outputFile];
    writeSuccess = YES;
  } @catch (NSException *exception) {
    NSLog(@"Error while writing to %@: %@", outputFilepath, exception);
    if (error) {
      *error = MakeError(@"data_loss_on_write");
    }
  }

  [outputFile close];

  if (!writeSuccess) {
    // Unable to successfully write all data.
    [[NSFileManager defaultManager] removeItemAtPath:outputFilepath error:nil];
    return;
  }

  if (![[NSFileManager defaultManager] moveItemAtPath:outputFilepath
                                               toPath:exposedFilepath
                                                error:nil]) {
    // Delete the tmp file if unable to move
    [[NSFileManager defaultManager] removeItemAtPath:outputFilepath error:nil];
    if (error) {
      *error = MakeError(@"data_loss_on_move");
    }
  }

  if (error && !*error) {
    _estimatedSpoolSize += _outputProtoSerializedSize;
  }

  return;
}

- (void)flushAndUpdateCountersLocked {
  NSError *error = nil;
  [self flushLockedWithError:&error];
  [_eventsFlushedCounter incrementBy:[_outputProto.recordsArray count]
                      forFieldValues:@[ ErrorToMetricFieldName(error) ]];

  // Clear output buffer.
  _outputProto = [[SNTPBLogBatch alloc] init];
  _outputProtoSerializedSize = 0;
}

- (void)flush {
  dispatch_sync(_flushQueue, ^{
    [self flushAndUpdateCountersLocked];
  });
}

- (BOOL)createDirectory:(NSString *)dir withError:(NSError **)error {
  BOOL isDir;
  // Check if the path exists
  if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir]) {
    // If path doesn't exist, attempt to create it
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil]) {
      if (error) {
        *error = MakeError(@"failed_to_create_dir");
      }
      return NO;
    }
  } else if (!isDir) {
    // The path existed, but it wasn't a directory
    if (error) {
      *error = MakeError(@"path_exists_not_directory");
    }
    return NO;
  }

  // If we made it here, the directory was created or already existed
  return YES;
}

- (BOOL)createSpoolDirectoriesWithError:(NSError **)error {
  return [self createDirectory:_baseDirectory withError:error] &&
         [self createDirectory:_tmpDirectory withError:error] &&
         [self createDirectory:_newDirectory withError:error];
}

+ (size_t)spoolDirectorySize:(NSString *)newDirectory withError:(NSError **)error {
  size_t totalSize = 0;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *enumerationError = nil;
  NSArray<NSString *> *filenames = [fm contentsOfDirectoryAtPath:newDirectory
                                                           error:&enumerationError];
  if (enumerationError) {
    *error = MakeError(@"spool_dir_enumeration_error");
    return 0;
  }

  for (NSString *filename in filenames) {
    NSError *attributesError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
      [fm attributesOfItemAtPath:[newDirectory stringByAppendingPathComponent:filename]
                           error:&attributesError];
    if (attributesError) {
      if (error) {
        *error = MakeError(@"spool_dir_attribute_retrieval_error");
      }
      continue;
    }

    totalSize += SNTRoundUpToNextPage([attributes fileSize]);
  }
  return totalSize;
}

- (void)logEvent:(SNTPBSantaMessage *)event {
  dispatch_sync(_flushQueue, ^{
    // Note: The `serializedSize` method is costly. In order to calculate the
    // size of the `_outputProto` accurately, we need to add both the serialized
    // size of the new event plus additional overhead incurred from adding the
    // new event to the current array of events. The `anyObjOverhead` is used
    // to store the calculated overhead when the first event is logged and the
    // overhead is then used when calculating `_outputProtoSerializedSize`.
    static size_t anyObjOverhead = 0;
    static dispatch_once_t onceToken;

    if (_outputProtoSerializedSize > _fileSizeThreshold) {
      [self flushAndUpdateCountersLocked];
    }

    NSError *error = nil;
    GPBAny *any = [GPBAny anyWithMessage:event error:nil];
    if (any) {
      [_outputProto.recordsArray addObject:any];

      dispatch_once(&onceToken, ^{
        size_t outputSerializedSize = [_outputProto serializedSize];
        size_t eventSerializedSize = [event serializedSize];
        if (outputSerializedSize > eventSerializedSize) {
          anyObjOverhead = outputSerializedSize - eventSerializedSize;
        }
      });

      _outputProtoSerializedSize += [event serializedSize] + anyObjOverhead;
    } else {
      error = MakeError(@"enqueue_error");
    }

    [_eventsQueuedCounter incrementForFieldValues:@[ ErrorToMetricFieldName(error) ]];
  });
}

/** Intentionally left no-op method for this class. */
- (void)logString:(NSString *)logLine {
}

@end

NS_ASSUME_NONNULL_END