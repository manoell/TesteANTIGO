#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()

// UI Components
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UILabel *dimensionsLabel;
@property (nonatomic, strong) UIView *topBarView;
@property (nonatomic, strong) UIView *buttonContainer;
@property (nonatomic, strong) CAGradientLayer *topGradient;
@property (nonatomic, strong) CAGradientLayer *bottomGradient;
@property (nonatomic, strong) UIImageView *iconView;

// State tracking
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, assign) CGRect expandedFrame;
@property (nonatomic, assign) CGRect minimizedFrame;
@property (nonatomic, assign) BOOL isDragging;

@end

@implementation FloatingWindow

#pragma mark - Initialization & Setup

- (instancetype)init {
    if (@available(iOS 13.0, *)) {
        UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self = [super initWithWindowScene:(UIWindowScene *)scene];
        } else {
            self = [super init];
        }
    } else {
        self = [super init];
    }
    
    if (self) {
        // Configurações básicas da janela
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
        self.layer.cornerRadius = 25;
        self.clipsToBounds = YES;
        
        // Configurar sombra
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        // Inicializar frames para os dois estados
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        
        // Frame para o estado expandido (quase tela cheia com margens)
        CGFloat margin = 20.0; // Margem pequena nas laterais, topo e base
        CGFloat expandedWidth = screenBounds.size.width - (2 * margin); // 95% da largura com margens
        CGFloat expandedHeight = screenBounds.size.height - (2 * margin) - 20; // Altura com margens, ajustada pra barra de status
        self.expandedFrame = CGRectMake(
            margin, // Margem à esquerda
            margin + 10, // Margem no topo + espaço pra barra de status
            expandedWidth,
            expandedHeight
        );
        
        // Frame para o estado minimizado (AssistiveTouch)
        CGFloat minimizedSize = 50;
        self.minimizedFrame = CGRectMake(
            screenBounds.size.width - minimizedSize - 20,
            screenBounds.size.height * 0.4,
            minimizedSize,
            minimizedSize
        );
        
        // Estado inicial (minimizado como AssistiveTouch)
        self.frame = self.minimizedFrame;
        self.windowState = FloatingWindowStateMinimized;
        
        // Configurações iniciais
        self.lastFrameSize = CGSizeZero;
        self.isPreviewActive = NO;
        self.isReceivingFrames = NO;
        self.currentFps = 0;
        
        // Configurar UI
        [self setupUI];
        [self setupGestureRecognizers];
        
        // Atualize a aparência baseada no estado inicial
        [self updateAppearanceForState:self.windowState];
        
        writeLog(@"[FloatingWindow] Janela flutuante inicializada em modo minimizado");
    }
    return self;
}

- (void)setupUI {
    // Container principal
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentView];
    
    // Layout para contentView preencher a janela
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    
    // Configurar componentes da UI
    [self setupVideoView];
    [self setupTopBar];
    [self setupBottomControls];
    [self setupLoadingIndicator];
    [self setupGradients];
    [self setupMinimizedIcon];
}

- (void)setupVideoView {
    // Usar RTCMTLVideoView para renderização eficiente de vídeo
    self.videoView = [[RTCMTLVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.videoView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
}

- (void)setupTopBar {
    // Barra superior com informações
    self.topBarView = [[UIView alloc] init];
    self.topBarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.topBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.topBarView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.topBarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.topBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.topBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.topBarView.heightAnchor constraintEqualToConstant:50],
    ]];
    
    // Label para status da conexão
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"WebRTC Preview";
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.topBarView addSubview:self.statusLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.topBarView.topAnchor constant:8],
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.topBarView.centerXAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.topBarView.widthAnchor constant:-20],
    ]];
    
    // Label para dimensões e FPS
    self.dimensionsLabel = [[UILabel alloc] init];
    self.dimensionsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.dimensionsLabel.text = @"";
    self.dimensionsLabel.textColor = [UIColor whiteColor];
    self.dimensionsLabel.textAlignment = NSTextAlignmentCenter;
    self.dimensionsLabel.backgroundColor = [UIColor clearColor];
    self.dimensionsLabel.font = [UIFont systemFontOfSize:12];
    [self.topBarView addSubview:self.dimensionsLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.dimensionsLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:4],
        [self.dimensionsLabel.centerXAnchor constraintEqualToAnchor:self.topBarView.centerXAnchor],
        [self.dimensionsLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.topBarView.widthAnchor constant:-20],
    ]];
}

- (void)setupBottomControls {
    // Container para botão
    self.buttonContainer = [[UIView alloc] init];
    self.buttonContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.buttonContainer.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:self.buttonContainer];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.buttonContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-20],
        [self.buttonContainer.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.buttonContainer.widthAnchor constraintEqualToConstant:180],
        [self.buttonContainer.heightAnchor constraintEqualToConstant:50],
    ]];
    
    // Botão de ativar/desativar
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor]; // Verde inicialmente
    self.toggleButton.layer.cornerRadius = 10;
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttonContainer addSubview:self.toggleButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.leadingAnchor constraintEqualToAnchor:self.buttonContainer.leadingAnchor],
        [self.toggleButton.trailingAnchor constraintEqualToAnchor:self.buttonContainer.trailingAnchor],
        [self.toggleButton.topAnchor constraintEqualToAnchor:self.buttonContainer.topAnchor],
        [self.toggleButton.bottomAnchor constraintEqualToAnchor:self.buttonContainer.bottomAnchor],
    ]];
}

- (void)setupLoadingIndicator {
    // Indicador de carregamento
    if (@available(iOS 13.0, *)) {
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.loadingIndicator.color = [UIColor whiteColor];
    } else {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        #pragma clang diagnostic pop
    }
    
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.contentView addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
}

- (void)setupMinimizedIcon {
    // Criar o ícone para o estado minimizado
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor whiteColor];
    [self addSubview:self.iconView];
    
    // Centralizar o ícone
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26]
    ]];
    
    // Definir o ícone inicial
    [self updateMinimizedIconWithState];
    
    // Inicialmente oculto até que a janela seja minimizada
    self.iconView.hidden = YES;
}

- (void)setupGradients {
    // Gradiente para topo
    self.topGradient = [CAGradientLayer layer];
    self.topGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0.8] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor]
    ];
    self.topGradient.locations = @[@0.0, @1.0];
    self.topGradient.startPoint = CGPointMake(0.5, 0.0);
    self.topGradient.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer insertSublayer:self.topGradient atIndex:0];
    
    // Gradiente para base
    self.bottomGradient = [CAGradientLayer layer];
    self.bottomGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0.8] CGColor]
    ];
    self.bottomGradient.locations = @[@0.0, @1.0];
    self.bottomGradient.startPoint = CGPointMake(0.5, 0.0);
    self.bottomGradient.endPoint = CGPointMake(0.5, 1.0);
    [self.contentView.layer insertSublayer:self.bottomGradient atIndex:0];
}

- (void)setupGestureRecognizers {
    // Gestor para mover a janela - Prioridade alta para melhor resposta
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    panGesture.maximumNumberOfTouches = 1;
    panGesture.minimumNumberOfTouches = 1;
    [self addGestureRecognizer:panGesture];
    
    // Tap para expandir/minimizar
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    
    // Configurar dependências entre gestos para evitar conflitos
    [tapGesture requireGestureRecognizerToFail:panGesture];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    
    // Atualizar layout dos gradientes
    self.topGradient.frame = CGRectMake(0, 0, self.bounds.size.width, 60);
    self.bottomGradient.frame = CGRectMake(0, self.bounds.size.height - 80, self.bounds.size.width, 80);
}

#pragma mark - Public Methods

- (void)show {
    // Configurar para o estado inicial
    self.frame = self.minimizedFrame;
    self.windowState = FloatingWindowStateMinimized;
    [self updateAppearanceForState:self.windowState];
    
    // Tornar visível
    self.hidden = NO;
    self.alpha = 0;
    
    // Animar entrada
    self.transform = CGAffineTransformMakeScale(0.5, 0.5);
    
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 0.8; // Começar com alfa reduzido para minimizado
    } completion:nil];
    
    [self makeKeyAndVisible];
    writeLog(@"[FloatingWindow] Janela flutuante mostrada");
}

- (void)hide {
    [self stopPreview];
    
    // Animar saída
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.5, 0.5);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    
    writeLog(@"[FloatingWindow] Janela flutuante ocultada");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        [self startPreview];
    }
}

- (void)startPreview {
    // Verificar se o WebRTCManager está presente
    if (!self.webRTCManager) {
        writeLog(@"[FloatingWindow] WebRTCManager não inicializado");
        [self updateConnectionStatus:@"Erro: gerenciador não inicializado"];
        return;
    }
    
    self.isPreviewActive = YES;
    [self.toggleButton setTitle:@"Desativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor redColor]; // Vermelho quando ativo
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    [self updateConnectionStatus:@"Conectando..."];
    
    // Iniciar WebRTC
    @try {
        [self.webRTCManager startWebRTC];
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exceção ao iniciar WebRTC: %@", exception);
        self.isPreviewActive = NO;
        [self.loadingIndicator stopAnimating];
        [self updateConnectionStatus:@"Erro ao iniciar conexão"];
        
        // Reverter UI
        [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
        return;
    }
    
    // Expandir se estiver minimizado
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    }
    
    // Atualizar ícone minimizado
    [self updateMinimizedIconWithState];
}

- (void)stopPreview {
    if (!self.isPreviewActive) return;
    
    self.isPreviewActive = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor greenColor]; // Verde quando desativado
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    [self updateConnectionStatus:@"Desconectado"];
    
    // Limpar dimensões
    self.dimensionsLabel.text = @"";
    
    // Marcar como não recebendo frames
    self.isReceivingFrames = NO;
    
    // Desconectar WebRTC
    if (self.webRTCManager) {
        @try {
            // Enviar mensagem bye
            [self.webRTCManager sendByeMessage];
            
            // Desativar após pequeno delay para garantir o envio da mensagem
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.webRTCManager stopWebRTC:YES];
            });
        } @catch (NSException *exception) {
            writeLog(@"[FloatingWindow] Exceção ao desativar WebRTC: %@", exception);
            [self.webRTCManager stopWebRTC:YES];
        }
    }
    
    // Atualizar ícone minimizado
    [self updateMinimizedIconWithState];
}

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
        
        // Atualizar estado visual (cor do ícone quando minimizado)
        [self updateMinimizedIconWithState];
    });
}

#pragma mark - State Management

- (void)setWindowState:(FloatingWindowState)windowState {
    if (_windowState == windowState) return;
    
    _windowState = windowState;
    [self updateAppearanceForState:windowState];
}

- (void)updateAppearanceForState:(FloatingWindowState)state {
    // Determinar e aplicar a aparência com base no estado
    switch (state) {
        case FloatingWindowStateMinimized:
            [self animateToMinimizedState];
            break;
            
        case FloatingWindowStateExpanded:
            [self animateToExpandedState];
            break;
    }
}

- (void)animateToMinimizedState {
    // Atualizar o ícone antes da animação
    [self updateMinimizedIconWithState];
    self.iconView.hidden = NO;
    
    // Animar para versão minimizada
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        // Aplicar frame minimizado
        self.frame = self.minimizedFrame;
        
        // Ajustar aparência para AssistiveTouch
        self.layer.cornerRadius = self.frame.size.width / 2;
        
        // Configurar transparência
        self.alpha = 0.8;
        
        // Ocultar elementos da UI
        self.topBarView.alpha = 0;
        self.buttonContainer.alpha = 0;
        self.videoView.alpha = 0;
        
        // Ajustar cor do fundo com base no estado
        [self updateBackgroundColorForState];
    } completion:^(BOOL finished) {
        // Confirmar que elementos estão ocultos
        self.topBarView.hidden = YES;
        self.buttonContainer.hidden = YES;
        self.videoView.hidden = YES;
    }];
}

- (void)animateToExpandedState {
    // Preparar para expandir
    self.topBarView.hidden = NO;
    self.buttonContainer.hidden = NO;
    self.videoView.hidden = NO;
    
    // Ocultar o ícone minimizado
    self.iconView.hidden = YES;
    
    // Animar para versão expandida
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        // Aplicar frame expandido
        self.frame = self.expandedFrame;
        
        // Ajustar aparência
        self.layer.cornerRadius = 12;
        
        // Configurar transparência
        self.alpha = 1.0;
        
        // Mostrar elementos da UI
        self.topBarView.alpha = 1.0;
        self.buttonContainer.alpha = 1.0;
        self.videoView.alpha = 1.0;
        
        // Fundo escuro
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
    } completion:nil];
}

- (void)updateBackgroundColorForState {
    // Atualizar a cor de fundo baseada no estado atual
    if (self.windowState != FloatingWindowStateMinimized) return;
    
    if (self.isPreviewActive) {
        if (self.isReceivingFrames) {
            // Verde quando recebendo frames
            self.backgroundColor = [UIColor colorWithRed:0.0 green:0.7 blue:0.0 alpha:0.9];
        } else {
            // Amarelo quando conectado mas sem receber
            self.backgroundColor = [UIColor colorWithRed:0.7 green:0.7 blue:0.0 alpha:0.9];
        }
    } else {
        // Cinza quando desconectado
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
    }
}

- (void)updateMinimizedIconWithState {
    UIImage *image = nil;
    
    if (@available(iOS 13.0, *)) {
        if (self.isPreviewActive) {
            image = [UIImage systemImageNamed:@"video.fill"]; // Ícone cheio quando ativo
            self.iconView.tintColor = [UIColor greenColor];   // Verde quando ativo
        } else {
            image = [UIImage systemImageNamed:@"video.slash"]; // Ícone cortado quando desativado
            self.iconView.tintColor = [UIColor redColor];     // Vermelho quando desativado
        }
    }
    
    if (!image) {
        // Fallback pra iOS < 13
        CGSize iconSize = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(iconSize, NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) {
            CGContextSetFillColorWithColor(context,
                self.isPreviewActive ? [UIColor greenColor].CGColor : [UIColor redColor].CGColor);
            CGContextFillEllipseInRect(context, CGRectMake(0, 0, iconSize.width, iconSize.height));
            image = UIGraphicsGetImageFromCurrentImageContext();
        }
        UIGraphicsEndImageContext();
    }
    
    self.iconView.image = image;
    [self updateBackgroundColorForState];
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    //writeLog(@"[FloatingWindow] Pan estado: %ld", (long)gesture.state);
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        if (self.windowState == FloatingWindowStateMinimized) {
            [self snapToEdgeIfNeeded];
        }
    }
}

- (void)snapToEdgeIfNeeded {
    // Implementar snap para a borda quando minimizado
    if (self.windowState != FloatingWindowStateMinimized) return;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat padding = 10;
    
    // Decidir para qual borda fazer snap (direita ou esquerda)
    if (center.x < screenBounds.size.width / 2) {
        // Snap para borda esquerda
        center.x = self.frame.size.width / 2 + padding;
    } else {
        // Snap para borda direita
        center.x = screenBounds.size.width - self.frame.size.width / 2 - padding;
    }
    
    // Animar o movimento
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.center = center;
    } completion:^(BOOL finished) {
        // Atualizar o frame minimizado
        self.minimizedFrame = self.frame;
    }];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.isDragging) {
        return;
    }
    
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    } else {
        // Verificar apenas o toggleButton
        CGPoint location = [gesture locationInView:self];
        BOOL tappedOnButton = NO;
        
        if (self.buttonContainer) {
            CGPoint pointInButtonContainer = [self.buttonContainer convertPoint:location fromView:self];
            if ([self.buttonContainer pointInside:pointInButtonContainer withEvent:nil]) {
                tappedOnButton = YES;
            }
        }
        
        if (!tappedOnButton) {
            [self setWindowState:FloatingWindowStateMinimized];
        }
    }
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    // Atualizar o registro do tamanho do frame
    self.lastFrameSize = size;
    
    // Marcar como recebendo frames apenas se as dimensões forem válidas
    if (size.width > 0 && size.height > 0) {
        self.isReceivingFrames = YES;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Parar indicador de carregamento
            [self.loadingIndicator stopAnimating];
            
            // Atualizar status e informações de dimensões
            [self updateConnectionStatus:@"Recebendo stream"];
            
            // Atualizar label de dimensões e FPS
            if (self.currentFps > 0) {
                self.dimensionsLabel.text = [NSString stringWithFormat:@"%dx%d @ %dfps",
                                          (int)size.width, (int)size.height, (int)self.currentFps];
            } else {
                self.dimensionsLabel.text = [NSString stringWithFormat:@"%dx%d",
                                          (int)size.width, (int)size.height];
            }
            
            // Atualizar aparência do ícone minimizado
            [self updateMinimizedIconWithState];
        });
    }
}

@end
