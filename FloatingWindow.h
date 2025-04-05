#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>
#import "WebRTCManager.h"

typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateMinimized,  // Versão minimizada tipo AssistiveTouch
    FloatingWindowStateExpanded    // Versão expandida com controles
};

@interface FloatingWindow : UIWindow <RTCVideoViewDelegate, WebRTCManagerDelegate>

@property (nonatomic, strong, readonly) RTCMTLVideoView *videoView;
@property (nonatomic, strong) WebRTCManager *webRTCManager;
@property (nonatomic, assign) FloatingWindowState windowState;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) float currentFps;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, strong) UILabel *statusLabel;

- (instancetype)init;
- (void)show;
- (void)hide;
- (void)togglePreview:(UIButton *)sender;
- (void)updateConnectionStatus:(NSString *)status;

@end
