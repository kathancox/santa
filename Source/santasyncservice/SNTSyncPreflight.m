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

#import "Source/santasyncservice/SNTSyncPreflight.h"

#import <MOLXPCConnection/MOLXPCConnection.h>

#import "Source/common/SNTCommon.h"
#import "Source/common/SNTConfigurator.h"
#import "Source/common/SNTLogging.h"
#import "Source/common/SNTSyncConstants.h"
#import "Source/common/SNTSystemInfo.h"
#import "Source/common/SNTXPCControlInterface.h"
#import "Source/santasyncservice/SNTSyncLogging.h"
#import "Source/santasyncservice/SNTSyncState.h"

@implementation SNTSyncPreflight

- (NSURL *)stageURL {
  NSString *stageName = [@"preflight" stringByAppendingFormat:@"/%@", self.syncState.machineID];
  return [NSURL URLWithString:stageName relativeToURL:self.syncState.syncBaseURL];
}

- (BOOL)sync {
  NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
  requestDict[kSerialNumber] = [SNTSystemInfo serialNumber];
  requestDict[kHostname] = [SNTSystemInfo longHostname];
  requestDict[kOSVer] = [SNTSystemInfo osVersion];
  requestDict[kOSBuild] = [SNTSystemInfo osBuild];
  requestDict[kModelIdentifier] = [SNTSystemInfo modelIdentifier];
  requestDict[kSantaVer] = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
  requestDict[kPrimaryUser] = self.syncState.machineOwner;
  if (self.syncState.pushNotificationsToken) {
    requestDict[kFCMToken] = self.syncState.pushNotificationsToken;
  }

  dispatch_group_t group = dispatch_group_create();
  dispatch_group_enter(group);
  [[self.daemonConn remoteObjectProxy]
    databaseRuleCounts:^(int64_t binary, int64_t certificate, int64_t compiler, int64_t transitive,
                         int64_t teamID) {
      requestDict[kBinaryRuleCount] = @(binary);
      requestDict[kCertificateRuleCount] = @(certificate);
      requestDict[kCompilerRuleCount] = @(compiler);
      requestDict[kTransitiveRuleCount] = @(transitive);
      requestDict[kTeamIDRuleCount] = @(teamID);
      dispatch_group_leave(group);
    }];

  dispatch_group_enter(group);
  [[self.daemonConn remoteObjectProxy] clientMode:^(SNTClientMode cm) {
    switch (cm) {
      case SNTClientModeMonitor: requestDict[kClientMode] = kClientModeMonitor; break;
      case SNTClientModeLockdown: requestDict[kClientMode] = kClientModeLockdown; break;
      default: break;
    }
    dispatch_group_leave(group);
  }];

  __block BOOL syncClean = NO;
  dispatch_group_enter(group);
  [[self.daemonConn remoteObjectProxy] syncCleanRequired:^(BOOL clean) {
    syncClean = clean;
    dispatch_group_leave(group);
  }];

  // Stop the sync if we are unable to communicate with daemon.
  if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) {
    SLOGE(@"Unable to communicate with daemon.");
    return NO;
  }

  // If user requested it or we've never had a successful sync, try from a clean slate.
  if (syncClean) {
    SLOGD(@"Clean sync requested by user");
    requestDict[kRequestCleanSync] = @YES;
  }

  NSURLRequest *req = [self requestWithDictionary:requestDict];
  NSDictionary *resp = [self performRequest:req];

  if (!resp) return NO;

  dispatch_group_enter(group);
  NSNumber *enableBundles = resp[kEnableBundles];
  if (!enableBundles) enableBundles = resp[kEnableBundlesDeprecated];
  [[self.daemonConn remoteObjectProxy] setEnableBundles:[enableBundles boolValue]
                                                  reply:^{
                                                    dispatch_group_leave(group);
                                                  }];

  dispatch_group_enter(group);
  NSNumber *enableTransitiveRules = resp[kEnableTransitiveRules];
  if (!enableTransitiveRules) enableTransitiveRules = resp[kEnableTransitiveRulesDeprecated];
  if (!enableTransitiveRules) enableTransitiveRules = resp[kEnableTransitiveRulesSuperDeprecated];
  BOOL enabled = [enableTransitiveRules boolValue];
  [[self.daemonConn remoteObjectProxy] setEnableTransitiveRules:enabled
                                                          reply:^{
                                                            dispatch_group_leave(group);
                                                          }];

  dispatch_group_enter(group);
  NSNumber *enableAllEventUpload = resp[kEnableAllEventUpload];
  [[self.daemonConn remoteObjectProxy] setEnableAllEventUpload:[enableAllEventUpload boolValue]
                                                         reply:^{
                                                           dispatch_group_leave(group);
                                                         }];

  dispatch_group_enter(group);
  NSNumber *disableUnknownEventUpload = resp[kDisableUnknownEventUpload];
  [[self.daemonConn remoteObjectProxy]
    setDisableUnknownEventUpload:[disableUnknownEventUpload boolValue]
                           reply:^{
                             dispatch_group_leave(group);
                           }];

  self.syncState.eventBatchSize = [resp[kBatchSize] unsignedIntegerValue] ?: kDefaultEventBatchSize;

  // Don't let these go too low
  NSUInteger FCMIntervalValue = [resp[kFCMFullSyncInterval] unsignedIntegerValue];
  self.syncState.pushNotificationsFullSyncInterval = (FCMIntervalValue < kDefaultFullSyncInterval)
                                                       ? kDefaultPushNotificationsFullSyncInterval
                                                       : FCMIntervalValue;
  FCMIntervalValue = [resp[kFCMGlobalRuleSyncDeadline] unsignedIntegerValue];
  self.syncState.pushNotificationsGlobalRuleSyncDeadline =
    (FCMIntervalValue < 60) ? kDefaultPushNotificationsGlobalRuleSyncDeadline : FCMIntervalValue;

  // Check if our sync interval has changed
  NSUInteger intervalValue = [resp[kFullSyncInterval] unsignedIntegerValue];
  self.syncState.fullSyncInterval = (intervalValue < 60) ? kDefaultFullSyncInterval : intervalValue;

  if ([resp[kClientMode] isEqual:kClientModeMonitor]) {
    self.syncState.clientMode = SNTClientModeMonitor;
  } else if ([resp[kClientMode] isEqual:kClientModeLockdown]) {
    self.syncState.clientMode = SNTClientModeLockdown;
  }

  if ([resp[kAllowedPathRegex] isKindOfClass:[NSString class]]) {
    self.syncState.allowlistRegex = resp[kAllowedPathRegex];
  } else if ([resp[kAllowedPathRegexDeprecated] isKindOfClass:[NSString class]]) {
    self.syncState.allowlistRegex = resp[kAllowedPathRegexDeprecated];
  }

  if ([resp[kBlockedPathRegex] isKindOfClass:[NSString class]]) {
    self.syncState.blocklistRegex = resp[kBlockedPathRegex];
  } else if ([resp[kBlockedPathRegexDeprecated] isKindOfClass:[NSString class]]) {
    self.syncState.blocklistRegex = resp[kBlockedPathRegexDeprecated];
  }

  if ([resp[kBlockUSBMount] boolValue]) {
    self.syncState.blockUSBMount = YES;
  }

  if ([resp[kRemountUSBMode] isKindOfClass:[NSArray class]]) {
    self.syncState.remountUSBMode = resp[kRemountUSBMode];
  }

  if ([resp[kCleanSync] boolValue]) {
    SLOGD(@"Clean sync requested by server");
    self.syncState.cleanSync = YES;
  }

  dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  return YES;
}

@end
