#import "KeyboardDataSyncBridge.h"

// Helper function to get App Group ID from Info.plist with fallback
static NSString *UnsaidAppGroupID(void) {
  NSString *gid = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"AppGroupID"];
  return gid.length ? gid : @"group.com.example.unsaid"; // optional default
}

@implementation KeyboardDataSyncBridge

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"com.unsaid/keyboard_data_sync"
            binaryMessenger:[registrar messenger]];
  KeyboardDataSyncBridge* instance = [[KeyboardDataSyncBridge alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* appGroupId = UnsaidAppGroupID();
  NSUserDefaults* sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:appGroupId];
  
  // Check if app group is available
  if (!sharedDefaults) {
    result([FlutterError errorWithCode:@"app_group_unavailable"
                               message:@"Shared app group could not be opened."
                               details:appGroupId]);
    return;
  }
  
  if ([@"getAllPendingKeyboardData" isEqualToString:call.method]) {
    NSArray *pendingData = [sharedDefaults arrayForKey:@"pendingKeyboardData"] ?: @[];
    result(pendingData);
    return;
  }
  
  if ([@"getKeyboardStorageMetadata" isEqualToString:call.method]) {
    NSDictionary *metadata = [sharedDefaults dictionaryForKey:@"keyboardStorageMetadata"] ?: @{};
    result(metadata);
    return;
  }
  
  if ([@"clearAllPendingKeyboardData" isEqualToString:call.method]) {
    [sharedDefaults removeObjectForKey:@"pendingKeyboardData"];
    [sharedDefaults removeObjectForKey:@"keyboardStorageMetadata"];
    // Removed deprecated synchronize call
    result(@YES);
    return;
  }
  
  result(FlutterMethodNotImplemented);
}

@end
