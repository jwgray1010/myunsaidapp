//
//  KeyboardDataSyncBridge.h
//  Runner
//
//  Objective-C bridge for keyboard data synchronization via App Groups
//

#ifndef KeyboardDataSyncBridge_h
#define KeyboardDataSyncBridge_h

#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>

@interface KeyboardDataSyncBridge : NSObject<FlutterPlugin>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

#endif /* KeyboardDataSyncBridge_h */
