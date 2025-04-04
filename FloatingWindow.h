#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

/**
 * Estados possíveis da FloatingWindow
 */
typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateMinimized,  // Versão minimizada tipo AssistiveTouch
    FloatingWindowStateExpanded    // Versão expandida com controles
};

/**
 * FloatingWindow
 *
 * Janela flutuante que exibe o preview do stream WebRTC.
 * Implementada para se comportar como AssistiveTouch quando minimizada.
 */
@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

/**
 * View para renderização direta do vídeo WebRTC
 */
@property (nonatomic, strong, readonly) RTCMTLVideoView *videoView;

/**
 * Gerenciador WebRTC para controle da conexão
 */
@property (nonatomic, strong) WebRTCManager *webRTCManager;

/**
 * Estado atual da janela
 */
@property (nonatomic, assign) FloatingWindowState windowState;

/**
 * Mostra se está recebendo frames
 */
@property (nonatomic, assign) BOOL isReceivingFrames;

/**
 * Frame rate atual
 */
@property (nonatomic, assign) float currentFps;

/**
 * Tamanho do último frame recebido
 */
@property (nonatomic, assign) CGSize lastFrameSize;

/**
 * Label para exibição do status da conexão
 */
@property (nonatomic, strong) UILabel *statusLabel;

#pragma mark - Initialization & Lifecycle Methods

/**
 * Inicializa a janela flutuante.
 */
- (instancetype)init;

/**
 * Exibe a janela flutuante.
 */
- (void)show;

/**
 * Oculta a janela flutuante e para o preview.
 */
- (void)hide;

/**
 * Alterna entre iniciar e parar o preview.
 */
- (void)togglePreview:(UIButton *)sender;

/**
 * Atualiza o status da conexão exibido.
 */
- (void)updateConnectionStatus:(NSString *)status;

@end
