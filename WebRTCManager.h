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

@protocol WebRTCManagerDelegate <NSObject>
- (void)didUpdateConnectionStatus:(NSString *)status;
- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack;
- (void)didChangeConnectionState:(WebRTCManagerState)state;
@end

@interface WebRTCManager : NSObject

@property (nonatomic, weak) id<WebRTCManagerDelegate> delegate;
@property (nonatomic, strong) NSString *serverIP;
@property (nonatomic, assign, readonly) WebRTCManagerState state;
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

- (instancetype)initWithDelegate:(id<WebRTCManagerDelegate>)delegate;
- (void)startWebRTC;
- (void)stopWebRTC:(BOOL)userInitiated;
- (void)sendByeMessage;
- (NSDictionary *)getConnectionStats;

@end

#endif /* WEBRTCMANAGER_H */
