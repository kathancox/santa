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

#include <EndpointSecurity/EndpointSecurity.h>
#include <Foundation/Foundation.h>
#include <bsm/libbsm.h>

CF_EXTERN_C_BEGIN
es_string_token_t MakeStringToken(const NSString *_Nonnull s);

es_file_t MakeESFile(const char *_Nonnull path);
es_process_t MakeESProcess(es_file_t *_Nonnull esFile);
es_message_t MakeESMessage(es_event_type_t eventType, es_process_t *_Nonnull instigator,
                           struct timespec ts);
CF_EXTERN_C_END

@class ESMessage;
typedef void (^ESMessageBuilderBlock)(ESMessage *_Nonnull builder);

// An ObjC builder wrapper around es_message_t
@interface ESMessage : NSObject
@property(nonatomic, readwrite, strong) NSString *_Nullable binaryPath;
@property(nonatomic, readwrite) es_file_t *_Nonnull executable;
@property(nonatomic, readwrite) es_process_t *_Nonnull process;
@property(nonatomic, readwrite) es_message_t *_Nonnull message;
@property(nonatomic, readonly) pid_t pid;

- (instancetype _Nonnull)initWithBlock:(ESMessageBuilderBlock _Nullable)block
  NS_DESIGNATED_INITIALIZER;
@end

@interface ESResponse : NSObject
@property(nonatomic) es_auth_result_t result;
@property(nonatomic) bool shouldCache;
@end

typedef void (^ESCallback)(ESResponse *_Nonnull);

// Singleton wrapper around all of the kernel-level EndpointSecurity framework functions.
@interface MockEndpointSecurity : NSObject
@property NSMutableArray *_Nonnull subscriptions;
- (void)reset;
- (void)registerResponseCallback:(es_event_type_t)t withCallback:(ESCallback _Nonnull)callback;
- (void)triggerHandler:(es_message_t *_Nonnull)msg;

///  Retrieve an initialized singleton MockEndpointSecurity object
+ (instancetype _Nonnull)mockEndpointSecurity;
@end

API_UNAVAILABLE(ios, tvos, watchos)
es_message_t *_Nullable es_copy_message(const es_message_t *_Nonnull msg);

API_UNAVAILABLE(ios, tvos, watchos)
void es_free_message(es_message_t *_Nonnull msg);

API_AVAILABLE(macos(10.15))
API_UNAVAILABLE(ios, tvos, watchos)
es_new_client_result_t es_new_client(es_client_t *_Nullable *_Nonnull client,
                                     es_handler_block_t _Nonnull handler);

API_AVAILABLE(macos(10.15)) API_UNAVAILABLE(ios, tvos, watchos)
es_return_t es_mute_process(es_client_t * _Nonnull client,
                            const audit_token_t * _Nonnull audit_token);

#if defined(MAC_OS_VERSION_12_0) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_12_0
API_AVAILABLE(macos(12.0))
API_UNAVAILABLE(ios, tvos, watchos)
es_return_t es_muted_paths_events(es_client_t *_Nonnull client,
                                  es_muted_paths_t *_Nonnull *_Nullable muted_paths);

API_AVAILABLE(macos(12.0))
API_UNAVAILABLE(ios, tvos, watchos)
void es_release_muted_paths(es_muted_paths_t *_Nonnull muted_paths);
#endif

API_AVAILABLE(macos(10.15))
API_UNAVAILABLE(ios, tvos, watchos)
es_respond_result_t es_respond_auth_result(es_client_t *_Nonnull client,
                                           const es_message_t *_Nonnull message,
                                           es_auth_result_t result, bool cache);

API_AVAILABLE(macos(10.15))
API_UNAVAILABLE(ios, tvos, watchos)
es_return_t es_subscribe(es_client_t *_Nonnull client, const es_event_type_t *_Nonnull events,
                         uint32_t event_count);

API_AVAILABLE(macos(10.15))
API_UNAVAILABLE(ios, tvos, watchos) es_return_t es_delete_client(es_client_t *_Nullable client);

API_AVAILABLE(macos(10.15))
API_UNAVAILABLE(ios, tvos, watchos)
es_return_t es_unsubscribe(es_client_t *_Nonnull client, const es_event_type_t *_Nonnull events,
                           uint32_t event_count);
