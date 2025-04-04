#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, assign) NSTimeInterval lastFrameTime;
@property (nonatomic, strong) UIPanGestureRecognizer *contentPanGesture;
@property (nonatomic, strong) UIButton *minimizeButton;
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, strong) UISlider *opacitySlider;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, assign) CGRect originalFrame;
@property (nonatomic, strong) UIView *statsView;
@property (nonatomic, strong) UILabel *connectionInfoLabel;
@property (nonatomic, strong) UILabel *videoStatsLabel;
@property (nonatomic, strong) UILabel *networkStatsLabel;
@property (nonatomic, strong) UIStackView *controlsStackView;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, assign) BOOL controlsVisible;
@property (nonatomic, assign) CGSize lastFrameSize;
@property (nonatomic, assign) BOOL dragInProgress;

// RTCMTLVideoView para renderização direta
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@end

@implementation FloatingWindow

#pragma mark - Initialization & Setup

- (instancetype)initWithFrame:(CGRect)frame {
    if (@available(iOS 13.0, *)) {
        UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            self = [super initWithWindowScene:(UIWindowScene *)scene];
        } else {
            self = [super initWithFrame:frame];
        }
    } else {
        self = [super initWithFrame:frame];
    }
    
    if (self) {
        self.frame = frame;
        self.originalFrame = frame;
        self.windowState = FloatingWindowStateNormal;
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.7].CGColor;
        
        // Melhorar a sombra para aparência mais moderna
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        [self setupUI];
        
        // Inicializar WebRTC manager
        self.webRTCManager = [[WebRTCManager alloc] initWithFloatingWindow:self];
        
        self.isPreviewActive = NO;
        self.lastFrameTime = 0;
        self.controlsVisible = YES;
        self.lastFrameSize = CGSizeZero;
        self.isTranslucent = YES;
        
        // Iniciar temporizador para auto-ocultar controles
        [self resetAutoHideTimer];
        
        writeLog(@"[FloatingWindow] Janela flutuante inicializada com UI aprimorada e RTCMTLVideoView");
    }
    return self;
}

- (void)setupUI {
    // Container principal com layout constraints
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
    
    // Configurar RTCMTLVideoView para renderização direta
    [self setupVideoView];
    
    // Configurar barra superior com status
    [self setupStatusBar];
    
    // Configurar botões de controle
    [self setupControlButtons];
    
    // Configurar indicador de carregamento
    [self setupLoadingIndicator];
    
    // Configurar área de estatísticas
    [self setupStatsView];
    
    // Configurar gestos
    [self setupGestureRecognizers];
    
    // Configurar fundo gradiente para barras de controle
    [self setupGradients];
}

- (void)setupVideoView {
    // Usar RTCMTLVideoView para renderização eficiente de vídeo
    self.videoView = [[RTCMTLVideoView alloc] init];
    if (!self.videoView) {
        writeLog(@"[FloatingWindow] Falha ao criar RTCMTLVideoView");
        return;
    }
    
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
    
    writeLog(@"[FloatingWindow] RTCMTLVideoView configurada com sucesso");
}

- (void)setupStatusBar {
    // Barra de status superior com gradiente
    UIView *statusBarView = [[UIView alloc] init];
    statusBarView.translatesAutoresizingMaskIntoConstraints = NO;
    statusBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:statusBarView];
    
    [NSLayoutConstraint activateConstraints:@[
        [statusBarView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [statusBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [statusBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [statusBarView.heightAnchor constraintEqualToConstant:44],
    ]];
    
    // Status Label com design aprimorado
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"WebRTC Preview";
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.layer.cornerRadius = 8;
    self.statusLabel.clipsToBounds = YES;
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    [statusBarView addSubview:self.statusLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.centerXAnchor constraintEqualToAnchor:statusBarView.centerXAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:statusBarView.widthAnchor constant:-80],
        [self.statusLabel.heightAnchor constraintEqualToConstant:30],
    ]];
    
    // Botões de controle da barra superior (removido botão de fechar como solicitado)
    
    self.minimizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.minimizeButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        [self.minimizeButton setImage:[UIImage systemImageNamed:@"minus.circle.fill"] forState:UIControlStateNormal];
    } else {
        [self.minimizeButton setTitle:@"-" forState:UIControlStateNormal];
    }
    [self.minimizeButton addTarget:self action:@selector(minimizeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.minimizeButton.tintColor = [UIColor whiteColor];
    [statusBarView addSubview:self.minimizeButton];
    
    self.infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.infoButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        [self.infoButton setImage:[UIImage systemImageNamed:@"info.circle.fill"] forState:UIControlStateNormal];
    } else {
        [self.infoButton setTitle:@"i" forState:UIControlStateNormal];
    }
    [self.infoButton addTarget:self action:@selector(infoButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.infoButton.tintColor = [UIColor whiteColor];
    [statusBarView addSubview:self.infoButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.minimizeButton.trailingAnchor constraintEqualToAnchor:statusBarView.trailingAnchor constant:-8],
        [self.minimizeButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.minimizeButton.widthAnchor constraintEqualToConstant:30],
        [self.minimizeButton.heightAnchor constraintEqualToConstant:30],
        
        [self.infoButton.trailingAnchor constraintEqualToAnchor:self.minimizeButton.leadingAnchor constant:-8],
        [self.infoButton.centerYAnchor constraintEqualToAnchor:statusBarView.centerYAnchor],
        [self.infoButton.widthAnchor constraintEqualToConstant:30],
        [self.infoButton.heightAnchor constraintEqualToConstant:30],
    ]];
}

- (void)setupControlButtons {
    // Barra de controles inferior
    UIView *controlBarView = [[UIView alloc] init];
    controlBarView.translatesAutoresizingMaskIntoConstraints = NO;
    controlBarView.backgroundColor = [UIColor clearColor];
    [self.contentView addSubview:controlBarView];
    
    [NSLayoutConstraint activateConstraints:@[
        [controlBarView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [controlBarView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [controlBarView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [controlBarView.heightAnchor constraintEqualToConstant:60],
    ]];
    
    // Stack view para controles
    self.controlsStackView = [[UIStackView alloc] init];
    self.controlsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.controlsStackView.distribution = UIStackViewDistributionFillEqually;
    self.controlsStackView.alignment = UIStackViewAlignmentCenter;
    self.controlsStackView.spacing = 10;
    [controlBarView addSubview:self.controlsStackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.controlsStackView.leadingAnchor constraintEqualToAnchor:controlBarView.leadingAnchor constant:10],
        [self.controlsStackView.trailingAnchor constraintEqualToAnchor:controlBarView.trailingAnchor constant:-10],
        [self.controlsStackView.centerYAnchor constraintEqualToAnchor:controlBarView.centerYAnchor],
        [self.controlsStackView.heightAnchor constraintEqualToConstant:40],
    ]];
    
    // Botão principal
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
    self.toggleButton.layer.cornerRadius = 8;
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.toggleButton.contentEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
    
    // Botão de configurações
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [settingsButton setImage:[UIImage systemImageNamed:@"gear"] forState:UIControlStateNormal];
    } else {
        [settingsButton setTitle:@"⚙️" forState:UIControlStateNormal];
    }
    settingsButton.tintColor = [UIColor whiteColor];
    [settingsButton addTarget:self action:@selector(showSettingsMenu:) forControlEvents:UIControlEventTouchUpInside];
    
    // Botão de estatísticas
    UIButton *statsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        [statsButton setImage:[UIImage systemImageNamed:@"chart.bar"] forState:UIControlStateNormal];
    } else {
        [statsButton setTitle:@"📊" forState:UIControlStateNormal];
    }
    statsButton.tintColor = [UIColor whiteColor];
    [statsButton addTarget:self action:@selector(toggleStatsView:) forControlEvents:UIControlEventTouchUpInside];
    
    // Adicionar botões ao stack view
    [self.controlsStackView addArrangedSubview:self.toggleButton];
    [self.controlsStackView addArrangedSubview:settingsButton];
    [self.controlsStackView addArrangedSubview:statsButton];
    
    // Configurar constraints específicos para o botão principal
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.widthAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
}

- (void)setupLoadingIndicator {
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

- (void)setupStatsView {
    // View para estatísticas
    self.statsView = [[UIView alloc] init];
    self.statsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statsView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
    self.statsView.layer.cornerRadius = 8;
    self.statsView.alpha = 0;
    self.statsView.clipsToBounds = YES;
    [self.contentView addSubview:self.statsView];
    
    // Labels para estatísticas
    self.connectionInfoLabel = [[UILabel alloc] init];
    self.connectionInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectionInfoLabel.font = [UIFont systemFontOfSize:12];
    self.connectionInfoLabel.textColor = [UIColor whiteColor];
    self.connectionInfoLabel.numberOfLines = 0;
    [self.statsView addSubview:self.connectionInfoLabel];
    
    self.videoStatsLabel = [[UILabel alloc] init];
    self.videoStatsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoStatsLabel.font = [UIFont systemFontOfSize:12];
    self.videoStatsLabel.textColor = [UIColor whiteColor];
    self.videoStatsLabel.numberOfLines = 0;
    [self.statsView addSubview:self.videoStatsLabel];
    
    self.networkStatsLabel = [[UILabel alloc] init];
    self.networkStatsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.networkStatsLabel.font = [UIFont systemFontOfSize:12];
    self.networkStatsLabel.textColor = [UIColor whiteColor];
    self.networkStatsLabel.numberOfLines = 0;
    [self.statsView addSubview:self.networkStatsLabel];
    
    // Posicionamento da view de estatísticas
    [NSLayoutConstraint activateConstraints:@[
        [self.statsView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [self.statsView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [self.statsView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-70],
        [self.statsView.heightAnchor constraintEqualToConstant:120],
        
        [self.connectionInfoLabel.topAnchor constraintEqualToAnchor:self.statsView.topAnchor constant:8],
        [self.connectionInfoLabel.leadingAnchor constraintEqualToAnchor:self.statsView.leadingAnchor constant:8],
        [self.connectionInfoLabel.trailingAnchor constraintEqualToAnchor:self.statsView.trailingAnchor constant:-8],
        
        [self.videoStatsLabel.topAnchor constraintEqualToAnchor:self.connectionInfoLabel.bottomAnchor constant:8],
        [self.videoStatsLabel.leadingAnchor constraintEqualToAnchor:self.statsView.leadingAnchor constant:8],
        [self.videoStatsLabel.trailingAnchor constraintEqualToAnchor:self.statsView.trailingAnchor constant:-8],
        
        [self.networkStatsLabel.topAnchor constraintEqualToAnchor:self.videoStatsLabel.bottomAnchor constant:8],
        [self.networkStatsLabel.leadingAnchor constraintEqualToAnchor:self.statsView.leadingAnchor constant:8],
        [self.networkStatsLabel.trailingAnchor constraintEqualToAnchor:self.statsView.trailingAnchor constant:-8],
        [self.networkStatsLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.statsView.bottomAnchor constant:-8],
    ]];
    
    // Inicializar com valores padrão
    self.connectionInfoLabel.text = @"Status: Desconectado";
    self.videoStatsLabel.text = @"Vídeo: --";
    self.networkStatsLabel.text = @"Rede: --";
}

- (void)setupGestureRecognizers {
    // Gesture para mover a janela
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:self.panGesture];
    
    // Gesture para mover o conteúdo (para reposicionamento com controles visíveis)
    self.contentPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleContentPan:)];
    [self.videoView addGestureRecognizer:self.contentPanGesture];
    self.videoView.userInteractionEnabled = YES;
    
    // Adicionar double tap para minimizar/maximizar
    [self addDoubleTapGesture];
    
    // Adicionar gestures de pinça e rotação
    self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    [self addGestureRecognizer:self.pinchGesture];
    
    self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPressGesture.minimumPressDuration = 0.5;
    [self addGestureRecognizer:self.longPressGesture];
    
    // Adicionar gestures de swipe para mostrar/ocultar métricas
    self.swipeUpGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeUp:)];
    self.swipeUpGesture.direction = UISwipeGestureRecognizerDirectionUp;
    [self addGestureRecognizer:self.swipeUpGesture];
    
    self.swipeDownGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipeDown:)];
    self.swipeDownGesture.direction = UISwipeGestureRecognizerDirectionDown;
    [self addGestureRecognizer:self.swipeDownGesture];
    
    // Tap para mostrar/ocultar controles
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    
    // Evitar conflitos entre gestures
    [self.panGesture requireGestureRecognizerToFail:tapGesture];
    [tapGesture requireGestureRecognizerToFail:self.doubleTapGesture];
}

- (void)setupGradients {
    // Gradiente para topo
    CAGradientLayer *topGradient = [CAGradientLayer layer];
    topGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor]
    ];
    topGradient.locations = @[@0.0, @1.0];
    topGradient.startPoint = CGPointMake(0.5, 0.0);
    topGradient.endPoint = CGPointMake(0.5, 1.0);
    topGradient.frame = CGRectMake(0, 0, self.bounds.size.width, 60);
    [self.contentView.layer insertSublayer:topGradient atIndex:0];
    
    // Gradiente para base
    CAGradientLayer *bottomGradient = [CAGradientLayer layer];
    bottomGradient.colors = @[
        (id)[[UIColor colorWithWhite:0 alpha:0] CGColor],
        (id)[[UIColor colorWithWhite:0 alpha:0.7] CGColor]
    ];
    bottomGradient.locations = @[@0.0, @1.0];
    bottomGradient.startPoint = CGPointMake(0.5, 0.0);
    bottomGradient.endPoint = CGPointMake(0.5, 1.0);
    bottomGradient.frame = CGRectMake(0, self.bounds.size.height - 60, self.bounds.size.width, 60);
    [self.contentView.layer insertSublayer:bottomGradient atIndex:0];
    
    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.colors = @[
        (id)[[UIColor colorWithRed:0.1 green:0.1 blue:0.2 alpha:0.9] CGColor],
        (id)[[UIColor colorWithRed:0.0 green:0.1 blue:0.3 alpha:0.8] CGColor]
    ];
    self.gradientLayer.frame = self.bounds;
    [self.layer insertSublayer:self.gradientLayer atIndex:0];
}

#pragma mark - Public Methods

- (void)show {
    self.hidden = NO;
    [self makeKeyAndVisible];
    
    // Animação de entrada
    self.transform = CGAffineTransformMakeScale(0.7, 0.7);
    self.alpha = 0;
    
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1;
    } completion:nil];
    
    writeLog(@"[FloatingWindow] Janela flutuante mostrada com animação");
}

- (void)hide {
    [self stopPreview];
    
    // Animação de saída
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.7, 0.7);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    
    writeLog(@"[FloatingWindow] Janela flutuante ocultada com animação");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
        [sender setTitle:@"Ativar Preview" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:0.8 alpha:1.0];
        self.isPreviewActive = NO;
    } else {
        [self startPreview];
        [sender setTitle:@"Desativar Preview" forState:UIControlStateNormal];
        sender.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
        self.isPreviewActive = YES;
    }
}

- (void)startPreview {
    self.statusLabel.text = @"Conectando...";
    writeLog(@"[FloatingWindow] Iniciando preview");
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    
    // Definir isPreviewActive para true ANTES de iniciar WebRTC
    self.isPreviewActive = YES;
    
    // Iniciar WebRTC com tratamento de erro
    @try {
        if (!self.webRTCManager) {
            writeLog(@"[FloatingWindow] ERRO: WebRTCManager não inicializado");
            [self updateConnectionStatus:@"Erro: Gerenciador não inicializado"];
            [self.loadingIndicator stopAnimating];
            return;
        }
        
        [self.webRTCManager startWebRTC];
    } @catch (NSException *exception) {
        writeLog(@"[FloatingWindow] Exceção ao iniciar WebRTC: %@", exception);
        self.isPreviewActive = NO;
        [self.loadingIndicator stopAnimating];
        [self updateConnectionStatus:@"Erro ao iniciar conexão"];
        return;
    }
    
    // Atualizar UI para modo conectado
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    }];
}

- (void)stopPreview {
    // Parar WebRTC
    [self.webRTCManager stopWebRTC:YES];
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    
    // Atualizar status
    [self updateConnectionStatus:@"Desconectado"];
    
    // Atualizar UI para modo desconectado
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    }];
    
    writeLog(@"[FloatingWindow] Preview parado");
}

- (void)updateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = status;
    });
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    writeLog(@"[FloatingWindow] Tamanho do vídeo alterado para: %@", NSStringFromCGSize(size));
    self.lastFrameSize = size;
    
    // Se estiver recebendo o primeiro frame válido, parar o indicador de carregamento
    if (size.width > 0 && size.height > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            // Atualizar feedback visual para o usuário
            [self updateConnectionStatus:[NSString stringWithFormat:@"Recebendo %dx%d", (int)size.width, (int)size.height]];
            
            // Atualizar estatísticas de vídeo
            self.videoStatsLabel.text = [NSString stringWithFormat:@"Vídeo: %dx%d", (int)size.width, (int)size.height];
        });
    }
}

#pragma mark - Window State Management

- (void)changeWindowState:(FloatingWindowState)newState animated:(BOOL)animated {
    // Salvar estado anterior para transição
    FloatingWindowState oldState = self.windowState;
    self.windowState = newState;
    
    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            [self applyStateChanges:oldState toState:newState];
        } completion:nil];
    } else {
        [self applyStateChanges:oldState toState:newState];
    }
    
    // Atualizar controles baseado no novo estado
    [self updateControlsForState:newState];
    
    // Reset timer para auto-ocultar controles
    [self resetAutoHideTimer];
}

- (void)applyStateChanges:(FloatingWindowState)fromState toState:(FloatingWindowState)toState {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    switch (toState) {
        case FloatingWindowStateMinimized: {
            // Salvar frame original ao minimizar
            if (fromState != FloatingWindowStateMinimized) {
                self.originalFrame = self.frame;
            }
            
            // Tamanho minimizado - um círculo pequeno
            CGFloat size = 60;
            
            // Manter a posição X/Y mas ajustar tamanho
            CGRect minimizedFrame = CGRectMake(
                self.frame.origin.x,
                self.frame.origin.y,
                size,
                size
            );
            
            // Garantir que está dentro da tela
            if (CGRectGetMaxX(minimizedFrame) > screenBounds.size.width) {
                minimizedFrame.origin.x = screenBounds.size.width - minimizedFrame.size.width;
            }
            
            if (CGRectGetMaxY(minimizedFrame) > screenBounds.size.height) {
                minimizedFrame.origin.y = screenBounds.size.height - minimizedFrame.size.height;
            }
            
            self.frame = minimizedFrame;
            self.layer.cornerRadius = size / 2; // Círculo perfeito
        }
            break;
            
        case FloatingWindowStateNormal:
            // Restaurar para o tamanho original
            if (fromState == FloatingWindowStateMinimized) {
                self.frame = self.originalFrame;
            } else {
                // Tamanho padrão se vier de outros estados
                CGFloat width = MIN(screenBounds.size.width * 0.7, 300);
                CGFloat height = width * 1.5;
                
                CGRect normalFrame = CGRectMake(
                    (screenBounds.size.width - width) / 2,
                    (screenBounds.size.height - height) / 2,
                    width,
                    height
                );
                
                self.frame = normalFrame;
            }
            self.layer.cornerRadius = 12;
            break;
            
        case FloatingWindowStateExpanded: {
            // Tamanho expandido - ocupar mais espaço com controles visíveis
            CGFloat padding = 40;
            CGFloat width = MIN(screenBounds.size.width - padding * 2, 400);
            CGFloat height = width * 1.4;
            
            CGRect expandedFrame = CGRectMake(
                (screenBounds.size.width - width) / 2,
                (screenBounds.size.height - height) / 2,
                width,
                height
            );
            
            self.frame = expandedFrame;
            self.layer.cornerRadius = 12;
        }
            break;
            
        case FloatingWindowStateFullscreen: {
            // Tela cheia - ocupa toda a tela com pequena borda
            CGFloat padding = 20;
            CGRect fullscreenFrame = CGRectInset(screenBounds, padding, padding);
            
            self.frame = fullscreenFrame;
            self.layer.cornerRadius = 12;
        }
            break;
    }
}

- (void)updateControlsForState:(FloatingWindowState)state {
    // Atualizar visibilidade e estilo dos controles baseado no estado
    switch (state) {
        case FloatingWindowStateMinimized:
            // Em modo minimizado, esconder a maioria dos controles
            [self hideControlsAnimated:NO];
            break;
            
        case FloatingWindowStateNormal:
        case FloatingWindowStateExpanded:
            // Mostrar controles normais
            [self showControlsAnimated:NO];
            break;
            
        case FloatingWindowStateFullscreen:
            // Mostrar controles extras no modo fullscreen
            [self showControlsAnimated:NO];
            [self showPerformanceStats:YES animated:NO];
            break;
    }
}

- (void)minimizeWindow:(BOOL)animated {
    [self changeWindowState:FloatingWindowStateMinimized animated:animated];
}

- (void)expandWindow:(BOOL)animated {
    [self changeWindowState:FloatingWindowStateNormal animated:animated];
}

- (void)maximizeWindow:(BOOL)animated {
    [self changeWindowState:FloatingWindowStateFullscreen animated:animated];
}

- (void)snapToNearestCorner:(BOOL)animated {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat threshold = 100; // Distância para considerar "perto" da borda
    
    // Determinar qual borda está mais próxima
    CGFloat distanceToLeft = self.center.x;
    CGFloat distanceToRight = screenBounds.size.width - self.center.x;
    CGFloat distanceToTop = self.center.y;
    CGFloat distanceToBottom = screenBounds.size.height - self.center.y;
    
    CGFloat padding = 10.0;
    CGPoint targetPoint = self.center;
    
    // Primeiro determina horizontal
    if (distanceToLeft < threshold) {
        targetPoint.x = self.frame.size.width/2 + padding;
    } else if (distanceToRight < threshold) {
        targetPoint.x = screenBounds.size.width - self.frame.size.width/2 - padding;
    }
    
    // Depois determina vertical
    if (distanceToTop < threshold) {
        targetPoint.y = self.frame.size.height/2 + padding;
    } else if (distanceToBottom < threshold) {
        targetPoint.y = screenBounds.size.height - self.frame.size.height/2 - padding;
    }
    
    // Se o ponto não mudou, não precisa animar
    if (CGPointEqualToPoint(targetPoint, self.center)) {
        return;
    }
    
    if (animated) {
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            self.center = targetPoint;
        } completion:nil];
    } else {
        self.center = targetPoint;
    }
}

- (void)setWindowTranslucency:(BOOL)translucent {
    // Ajustar transparência da janela
    self.isTranslucent = translucent;
    
    if (translucent) {
        [UIView animateWithDuration:0.3 animations:^{
            self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        }];
    } else {
        [UIView animateWithDuration:0.3 animations:^{
            self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0];
        }];
    }
}

#pragma mark - UI Control Methods

- (void)showControlsAnimated:(BOOL)animated {
    if (self.windowState == FloatingWindowStateMinimized) {
        return;
    }
    
    self.controlsVisible = YES;
    [self invalidateAutoHideTimer];
    
    void (^showAnimations)(void) = ^{
        self.minimizeButton.alpha = 1.0;
        self.infoButton.alpha = 1.0;
        self.controlsStackView.alpha = 1.0;
        self.statusLabel.alpha = 1.0;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.3 animations:showAnimations];
    } else {
        showAnimations();
    }
    
    [self resetAutoHideTimer];
}

- (void)hideControlsAnimated:(BOOL)animated {
    self.controlsVisible = NO;
    
    void (^hideAnimations)(void) = ^{
        self.minimizeButton.alpha = 0.0;
        self.infoButton.alpha = 0.0;
        self.controlsStackView.alpha = 0.0;
        
        // Manter status parcialmente visível
        self.statusLabel.alpha = 0.7;
    };
    
    if (animated) {
        [UIView animateWithDuration:0.3 animations:hideAnimations];
    } else {
        hideAnimations();
    }
}

- (void)showDiagnosticInfo:(BOOL)show animated:(BOOL)animated {
    if (!self.diagnosticView) {
        // Criar view de diagnóstico sob demanda
        self.diagnosticView = [[UIView alloc] init];
        self.diagnosticView.translatesAutoresizingMaskIntoConstraints = NO;
        self.diagnosticView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        self.diagnosticView.layer.cornerRadius = 8;
        self.diagnosticView.alpha = 0;
        [self.contentView addSubview:self.diagnosticView];
        
        // Posicionar no topo direito
        [NSLayoutConstraint activateConstraints:@[
            [self.diagnosticView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:50],
            [self.diagnosticView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [self.diagnosticView.widthAnchor constraintEqualToConstant:150],
            [self.diagnosticView.heightAnchor constraintEqualToConstant:100],
        ]];
        
        // Adicionar label para informações
        UILabel *diagLabel = [[UILabel alloc] init];
        diagLabel.translatesAutoresizingMaskIntoConstraints = NO;
        diagLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        diagLabel.textColor = [UIColor whiteColor];
        diagLabel.numberOfLines = 0;
        diagLabel.text = @"Sistema: iOS\nWebRTC: Ativo\nConexão: OK\nQualidade: Alta";
        [self.diagnosticView addSubview:diagLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [diagLabel.topAnchor constraintEqualToAnchor:self.diagnosticView.topAnchor constant:8],
            [diagLabel.leadingAnchor constraintEqualToAnchor:self.diagnosticView.leadingAnchor constant:8],
            [diagLabel.trailingAnchor constraintEqualToAnchor:self.diagnosticView.trailingAnchor constant:-8],
            [diagLabel.bottomAnchor constraintEqualToAnchor:self.diagnosticView.bottomAnchor constant:-8],
        ]];
    }
    
    if (animated) {
        [UIView animateWithDuration:0.3 animations:^{
            self.diagnosticView.alpha = show ? 1.0 : 0.0;
        }];
    } else {
        self.diagnosticView.alpha = show ? 1.0 : 0.0;
    }
}

- (void)showPerformanceStats:(BOOL)show animated:(BOOL)animated {
    if (animated) {
        [UIView animateWithDuration:0.3 animations:^{
            self.statsView.alpha = show ? 1.0 : 0.0;
        }];
    } else {
        self.statsView.alpha = show ? 1.0 : 0.0;
    }
    
    self.showPerformanceMetrics = show;
}

- (void)showAdvancedControlPanel:(BOOL)show animated:(BOOL)animated {
    // Implementar quando necessário - painel de controles avançados
    self.showAdvancedControls = show;
}

- (void)showSettingsMenu:(UIView *)sender {
    // Criar um menu de ações
    if (@available(iOS 13.0, *)) {
        UIAlertController *actionSheet = [UIAlertController
                                          alertControllerWithTitle:@"Configurações"
                                          message:nil
                                          preferredStyle:UIAlertControllerStyleActionSheet];
        
        // Ação para ajustar opacidade
        [actionSheet addAction:[UIAlertAction
                               actionWithTitle:self.isTranslucent ? @"Modo Sólido" : @"Modo Transparente"
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction * _Nonnull action) {
            [self setWindowTranslucency:!self.isTranslucent];
        }]];
        
        // Ação para mostrar estatísticas
        [actionSheet addAction:[UIAlertAction
                               actionWithTitle:self.showPerformanceMetrics ? @"Ocultar Estatísticas" : @"Mostrar Estatísticas"
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction * _Nonnull action) {
            [self showPerformanceStats:!self.showPerformanceMetrics animated:YES];
        }]];
        
        // Ação para tela cheia
        [actionSheet addAction:[UIAlertAction
                               actionWithTitle:@"Tela Cheia"
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction * _Nonnull action) {
            [self maximizeWindow:YES];
        }]];
        
        // Ação para tamanho normal
        [actionSheet addAction:[UIAlertAction
                               actionWithTitle:@"Tamanho Normal"
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction * _Nonnull action) {
            [self changeWindowState:FloatingWindowStateNormal animated:YES];
        }]];
        
        // Botão Cancelar
        [actionSheet addAction:[UIAlertAction
                               actionWithTitle:@"Cancelar"
                               style:UIAlertActionStyleCancel
                               handler:nil]];
        
        // Apresentar a partir desta janela
        UIViewController *rootVC = [[UIViewController alloc] init];
        self.rootViewController = rootVC;
        [rootVC presentViewController:actionSheet animated:YES completion:nil];
        
        // Correção para iPad
        UIPopoverPresentationController *popover = actionSheet.popoverPresentationController;
        if (popover) {
            popover.sourceView = sender;
            popover.sourceRect = sender.bounds;
            popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
        }
    }
}

- (void)updateStatistics {
    if (self.webRTCManager) {
        // Obter estatísticas e atualizar labels
        NSDictionary *stats = [self.webRTCManager getConnectionStats];
        if (stats) {
            // Estatísticas de rede
            NSString *networkStatsText = [NSString stringWithFormat:@"Rede: %@\nLatência: %@\nPacotes: %@",
                                       stats[@"connectionType"] ?: @"--",
                                       stats[@"rtt"] ?: @"--",
                                       stats[@"packetsReceived"] ?: @"--"];
            
            self.networkStatsLabel.text = networkStatsText;
        }
    }
}

#pragma mark - Timer Management

- (void)resetAutoHideTimer {
    [self invalidateAutoHideTimer];
    
    // Apenas criar timer se estiver conectado e não estiver minimizado ou arrastando
    if (self.isPreviewActive && self.windowState != FloatingWindowStateMinimized && !self.dragInProgress) {
        self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          target:self
                                                        selector:@selector(autoHideControls)
                                                        userInfo:nil
                                                         repeats:NO];
    }
}

- (void)invalidateAutoHideTimer {
    if (self.autoHideTimer) {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
    }
}

- (void)autoHideControls {
    if (self.controlsVisible && !self.dragInProgress) {
        [self hideControlsAnimated:YES];
    }
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.lastPosition = self.center;
            self.dragInProgress = YES;
            [self showControlsAnimated:YES];
            break;
            
        case UIGestureRecognizerStateChanged: {
            CGPoint newCenter = CGPointMake(self.lastPosition.x + translation.x,
                                            self.lastPosition.y + translation.y);
            
            // Garantir que a janela não saia completamente da tela
            CGRect bounds = [UIScreen mainScreen].bounds;
            CGFloat halfWidth = self.bounds.size.width / 2;
            CGFloat halfHeight = self.bounds.size.height / 2;
            
            // Limitar X
            if (newCenter.x - halfWidth < 0) {
                newCenter.x = halfWidth;
            } else if (newCenter.x + halfWidth > bounds.size.width) {
                newCenter.x = bounds.size.width - halfWidth;
            }
            
            // Limitar Y
            if (newCenter.y - halfHeight < 0) {
                newCenter.y = halfHeight;
            } else if (newCenter.y + halfHeight > bounds.size.height) {
                newCenter.y = bounds.size.height - halfHeight;
            }
            
            self.center = newCenter;
            break;
        }
            
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            self.dragInProgress = NO;
            [self snapToNearestCorner:YES];
            [self resetAutoHideTimer];
            break;
            
        default:
            break;
    }
}

- (void)handleContentPan:(UIPanGestureRecognizer *)gesture {
    // Semelhante ao handlePan, mas para quando o arrasto ocorre no conteúdo
    // Útil para quando os controles estão visíveis
    [self handlePan:gesture];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // Alternar entre estados quando houver duplo toque
    switch (self.windowState) {
        case FloatingWindowStateMinimized:
            [self expandWindow:YES];
            break;
            
        case FloatingWindowStateNormal:
            [self maximizeWindow:YES];
            break;
            
        case FloatingWindowStateExpanded:
        case FloatingWindowStateFullscreen:
            [self minimizeWindow:YES];
            break;
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gesture {
    // Implementar redimensionamento com gesto de pinça
    static CGRect initialFrame;
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            initialFrame = self.frame;
            break;
            
        case UIGestureRecognizerStateChanged: {
            CGFloat scale = gesture.scale;
            CGRect newFrame = CGRectMake(
                initialFrame.origin.x - (initialFrame.size.width * (scale - 1)) / 2,
                initialFrame.origin.y - (initialFrame.size.height * (scale - 1)) / 2,
                initialFrame.size.width * scale,
                initialFrame.size.height * scale
            );
            
            // Limitar tamanho mínimo e máximo
            CGFloat minSize = 60;
            CGFloat maxWidth = [UIScreen mainScreen].bounds.size.width * 0.95;
            CGFloat maxHeight = [UIScreen mainScreen].bounds.size.height * 0.95;
            
            if (newFrame.size.width >= minSize && newFrame.size.height >= minSize &&
                newFrame.size.width <= maxWidth && newFrame.size.height <= maxHeight) {
                self.frame = newFrame;
            }
            break;
        }
            
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            // Determinar estado baseado no tamanho final
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            CGFloat relativeWidth = self.frame.size.width / screenWidth;
            
            if (relativeWidth < 0.3) {
                [self minimizeWindow:YES];
            } else if (relativeWidth > 0.7) {
                [self maximizeWindow:YES];
            } else {
                [self expandWindow:YES];
            }
            break;
        }
            
        default:
            break;
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // Mostrar menu de configurações
        [self showSettingsMenu:gesture.view];
    }
}

- (void)handleSwipeUp:(UISwipeGestureRecognizer *)gesture {
    // Esconder métricas com swipe para cima
    if (self.showPerformanceMetrics) {
        [self showPerformanceStats:NO animated:YES];
    }
}

- (void)handleSwipeDown:(UISwipeGestureRecognizer *)gesture {
    // Mostrar métricas com swipe para baixo
    if (!self.showPerformanceMetrics) {
        [self showPerformanceStats:YES animated:YES];
    }
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    // Mostrar/esconder controles com toque único
    if (self.controlsVisible) {
        [self hideControlsAnimated:YES];
    } else {
        [self showControlsAnimated:YES];
    }
}

#pragma mark - Controls Actions

- (void)minimizeButtonTapped {
    // Alternar entre minimizado e normal
    if (self.windowState == FloatingWindowStateMinimized) {
        [self expandWindow:YES];
    } else {
        [self minimizeWindow:YES];
    }
}

- (void)infoButtonTapped {
    // Mostrar estatísticas
    [self showPerformanceStats:!self.showPerformanceMetrics animated:YES];
}

- (void)toggleStatsView:(UIButton *)sender {
    // Alternar visibilidade do painel de estatísticas
    [self showPerformanceStats:!self.showPerformanceMetrics animated:YES];
}

- (void)addDoubleTapGesture {
    // Gesture de duplo toque para minimizar/maximizar
    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    self.doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:self.doubleTapGesture];
}

@end
