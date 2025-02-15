/// Copyright 2015 Google Inc. All rights reserved.
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

#import <Foundation/Foundation.h>
#import <MOLCertificate/MOLCertificate.h>

#import "Source/common/SNTCommonEnums.h"
#import "Source/common/SNTCommon.h"

@class SNTRule;
@class SNTStoredEvent;
@class MOLXPCConnection;

///
///  Protocol implemented by santad and utilized by santactl (unprivileged operations)
///
@protocol SNTUnprivilegedDaemonControlXPC

///
///  Cache Ops
///
- (void)cacheCounts:(void (^)(uint64_t rootCache, uint64_t nonRootCache))reply;
- (void)cacheBucketCount:(void (^)(NSArray *))reply;
- (void)checkCacheForVnodeID:(santa_vnode_id_t)vnodeID withReply:(void (^)(santa_action_t))reply;

///
///  Database ops
///
- (void)databaseRuleCounts:(void (^)(int64_t binary, int64_t certificate, int64_t compiler,
                                     int64_t transitive, int64_t teamID))reply;
- (void)databaseEventCount:(void (^)(int64_t count))reply;
- (void)staticRuleCount:(void (^)(int64_t count))reply;

///
///  Decision ops
///

///
///  @param filePath A Path to the file, can be nil.
///  @param fileSHA256 The pre-calculated SHA256 hash for the file, can be nil. If nil the hash will
///                    be calculated by this method from the filePath.
///  @param certificateSHA256 A SHA256 hash of the signing certificate, can be nil.
///  @note If fileInfo and signingCertificate are both passed in, the most specific rule will be
///        returned. Binary rules take precedence over cert rules.
///
- (void)decisionForFilePath:(NSString *)filePath
                 fileSHA256:(NSString *)fileSHA256
          certificateSHA256:(NSString *)certificateSHA256
                     teamID:(NSString *)teamID
                      reply:(void (^)(SNTEventState))reply;

///
///  Config ops
///
- (void)watchdogInfo:(void (^)(uint64_t, uint64_t, double, double))reply;
- (void)clientMode:(void (^)(SNTClientMode))reply;
- (void)fullSyncLastSuccess:(void (^)(NSDate *))reply;
- (void)ruleSyncLastSuccess:(void (^)(NSDate *))reply;
- (void)syncCleanRequired:(void (^)(BOOL))reply;
- (void)enableBundles:(void (^)(BOOL))reply;
- (void)enableTransitiveRules:(void (^)(BOOL))reply;

///
/// Metrics ops
///
- (void)metrics:(void (^)(NSDictionary *))reply;

///
///  GUI Ops
///
- (void)setNotificationListener:(NSXPCListenerEndpoint *)listener;

///
///  Syncd Ops
///
- (void)pushNotifications:(void (^)(BOOL))reply;

///
///  Bundle Ops
///
- (void)syncBundleEvent:(SNTStoredEvent *)event relatedEvents:(NSArray<SNTStoredEvent *> *)events;

@end

@interface SNTXPCUnprivilegedControlInterface : NSObject

///
///  Returns an initialized NSXPCInterface for the SNTUnprivilegedDaemonControlXPC protocol.
///  Ensures any methods that accept custom classes as arguments are set-up before returning
///
+ (NSXPCInterface *)controlInterface;

///
///  Internal method used to initialize the control interface
///
+ (void)initializeControlInterface:(NSXPCInterface *)r;

@end
