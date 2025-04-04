#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;

typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,
    WebRTCManagerStateConnecting,
    WebRTCManagerStateConnected,
    WebRTCManagerStateError,
    WebRTCManagerStateReconnecting
};

@interface WebRTCManager : NSObject

@property (nonatomic, weak) FloatingWindow *floatingWindow;
@property (nonatomic, strong) NSString *serverIP;

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;
- (void)startWebRTC;
- (void)stopWebRTC:(BOOL)userInitiated;
- (void)sendByeMessage;
- (NSDictionary *)getConnectionStats;

@end

#endif /* WEBRTCMANAGER_H */
