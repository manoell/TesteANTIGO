#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>
#import "WebRTCManager.h"

// Janela simplificada apenas para visualização do preview
@interface FloatingWindow : UIWindow

@property (nonatomic, strong) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) WebRTCManager *webRTCManager;

// Métodos para criar e destruir a janela
+ (void)showWithWebRTCManager:(WebRTCManager *)manager;
+ (void)destroy;

@end
