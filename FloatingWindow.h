#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

@class WebRTCManager;

/**
 * Estados possíveis da FloatingWindow
 */
typedef NS_ENUM(NSInteger, FloatingWindowState) {
    FloatingWindowStateNormal,     // Tamanho normal
    FloatingWindowStateMinimized,  // Versão minimizada
    FloatingWindowStateExpanded,   // Versão expandida com controles
    FloatingWindowStateFullscreen  // Versão em tela cheia
};

/**
 * FloatingWindow
 *
 * Janela flutuante aprimorada que exibe o preview do stream WebRTC e permite controlar a conexão.
 * Inclui funcionalidades para manipulação e visualização do vídeo em alta resolução.
 * Suporta múltiplos gestos, modos de visualização e exibição de métricas.
 * Usa RTCMTLVideoView para renderização eficiente.
 */
@interface FloatingWindow : UIWindow <RTCVideoViewDelegate>

#pragma mark - Properties

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
 * Exibir métricas de performance
 */
@property (nonatomic, assign) BOOL showPerformanceMetrics;

/**
 * Exibir estatísticas da conexão
 */
@property (nonatomic, assign) BOOL showConnectionStats;

/**
 * Exibir controles avançados
 */
@property (nonatomic, assign) BOOL showAdvancedControls;

/**
 * Mostra se o bloco de transparência está ativo
 */
@property (nonatomic, assign) BOOL isTranslucent;

#pragma mark - UI Components

/**
 * Botão para ativar/desativar o preview
 */
@property (nonatomic, strong) UIButton *toggleButton;

/**
 * Label para exibição do status da conexão
 */
@property (nonatomic, strong) UILabel *statusLabel;

/**
 * Label para estatísticas de conexão
 */
@property (nonatomic, strong) UILabel *statsLabel;

/**
 * View container para componentes da UI
 */
@property (nonatomic, strong) UIView *contentView;

/**
 * Toolbar com botões de controle
 */
@property (nonatomic, strong) UIToolbar *controlToolbar;

/**
 * View que contém informações de diagnóstico
 */
@property (nonatomic, strong) UIView *diagnosticView;

#pragma mark - Gesture Recognizers

/**
 * Gesture recognizer para mover a janela
 */
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

/**
 * Gesture de duplo toque para minimizar/maximizar
 */
@property (nonatomic, strong) UITapGestureRecognizer *doubleTapGesture;

/**
 * Gesture de pinça para redimensionar
 */
@property (nonatomic, strong) UIPinchGestureRecognizer *pinchGesture;

/**
 * Gesture de toque longo para mostrar menu de opções
 */
@property (nonatomic, strong) UILongPressGestureRecognizer *longPressGesture;

/**
 * Gesture de deslizar para baixo para mostrar métricas
 */
@property (nonatomic, strong) UISwipeGestureRecognizer *swipeDownGesture;

/**
 * Gesture de deslizar para cima para esconder métricas
 */
@property (nonatomic, strong) UISwipeGestureRecognizer *swipeUpGesture;

#pragma mark - Initialization & Lifecycle Methods

/**
 * Inicializa a janela flutuante com um quadro específico.
 * @param frame Retângulo definindo a posição e tamanho da janela.
 * @return Nova instância da janela flutuante.
 */
- (instancetype)initWithFrame:(CGRect)frame;

/**
 * Exibe a janela flutuante.
 */
- (void)show;

/**
 * Oculta a janela flutuante e para o preview.
 */
- (void)hide;

#pragma mark - Preview Control Methods

/**
 * Alterna entre iniciar e parar o preview.
 * @param sender Botão que acionou a ação.
 */
- (void)togglePreview:(UIButton *)sender;

/**
 * Inicia o preview WebRTC.
 * Conecta ao servidor e começa a receber o stream.
 */
- (void)startPreview;

/**
 * Para o preview WebRTC.
 * Desconecta do servidor e limpa a imagem.
 */
- (void)stopPreview;

/**
 * Atualiza o status da conexão exibido.
 * Também adapta a cor do indicador conforme o status.
 * @param status String de status a ser exibida.
 */
- (void)updateConnectionStatus:(NSString *)status;

#pragma mark - Window Management Methods

/**
 * Alterna entre diferentes estados da janela (normal, minimizado, expandido, etc.)
 * @param newState Novo estado da janela.
 * @param animated Se a transição deve ser animada.
 */
- (void)changeWindowState:(FloatingWindowState)newState animated:(BOOL)animated;

/**
 * Minimiza a janela para um estado compacto.
 * @param animated Se a transição deve ser animada.
 */
- (void)minimizeWindow:(BOOL)animated;

/**
 * Expande a janela para um tamanho normal/médio.
 * @param animated Se a transição deve ser animada.
 */
- (void)expandWindow:(BOOL)animated;

/**
 * Expande a janela para ocupar toda a tela.
 * @param animated Se a transição deve ser animada.
 */
- (void)maximizeWindow:(BOOL)animated;

/**
 * Move a janela para o canto mais próximo da tela.
 * @param animated Se a movimentação deve ser animada.
 */
- (void)snapToNearestCorner:(BOOL)animated;

/**
 * Ajusta a transparência da janela.
 * @param translucent Se a janela deve ficar translúcida/transparente.
 */
- (void)setWindowTranslucency:(BOOL)translucent;

#pragma mark - UI Display Methods

/**
 * Mostra/esconde informações de diagnóstico.
 * @param show Se deve mostrar ou esconder as informações.
 * @param animated Se a transição deve ser animada.
 */
- (void)showDiagnosticInfo:(BOOL)show animated:(BOOL)animated;

/**
 * Mostra/esconde estatísticas de desempenho.
 * @param show Se deve mostrar ou esconder as estatísticas.
 * @param animated Se a transição deve ser animada.
 */
- (void)showPerformanceStats:(BOOL)show animated:(BOOL)animated;

/**
 * Mostra/esconde controles avançados.
 * @param show Se deve mostrar ou esconder os controles.
 * @param animated Se a transição deve ser animada.
 */
- (void)showAdvancedControlPanel:(BOOL)show animated:(BOOL)animated;

/**
 * Exibe um menu de opções.
 * @param sender View que acionou o menu (para posicionamento).
 */
- (void)showSettingsMenu:(UIView *)sender;

/**
 * Atualiza estatísticas exibidas na interface.
 * Coleta estatísticas do WebRTCManager e as exibe formatadas.
 */
- (void)updateStatistics;

@end
