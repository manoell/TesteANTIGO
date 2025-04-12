#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

// Forward declarations
@class WebRTCFrameProvider;

// Enumerações de estados da janela
typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateMinimized,  // Minimized version like AssistiveTouch
    FloatingWindowStateExpanded    // Expanded version with controls
};

@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

@property (nonatomic, strong, readonly) RTCMTLVideoView *videoView;
@property (nonatomic, assign) FloatingWindowState windowState;
@property (nonatomic, assign) BOOL isReceivingFrames;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, assign) BOOL isSubstitutionActive;  // Propriedade para controlar estado do burlador
@property (nonatomic, assign) BOOL isPreviewActive;       // Indica se o preview está ativo

// UI Elements
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *substitutionButton;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;

- (instancetype)init;
- (void)show;
- (void)hide;
- (void)togglePreview:(UIButton *)sender;
- (void)updateConnectionStatus:(NSString *)status;
- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack;
- (void)startPreview;  // Adicionado para resolver erro
- (void)stopPreview;
- (void)updateMinimizedIconWithState;

@end
