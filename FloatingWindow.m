#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "logger.h"

@interface FloatingWindow ()

// Main UI Components
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *substitutionButton; // Botão para burlador
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) NSTimer *previewUpdateTimer; // Timer para atualizar preview

// State tracking
@property (nonatomic, assign) CGPoint lastPosition;
@property (nonatomic, assign) BOOL isPreviewActive;
@property (nonatomic, assign) CGRect expandedFrame;
@property (nonatomic, assign) CGRect minimizedFrame;
@property (nonatomic, assign) BOOL isDragging;

@end

@implementation FloatingWindow

#pragma mark - Initialization

- (instancetype)init {
    // Setup with window scene for iOS 13+
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
        // Basic window configuration
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
        self.layer.cornerRadius = 25;
        self.clipsToBounds = YES;
        
        // Configure shadow
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        // Initialize frames for both states
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        
        // Frame for expanded state (almost full screen with margins)
        CGFloat margin = 20.0;
        CGFloat expandedWidth = screenBounds.size.width - (2 * margin);
        CGFloat expandedHeight = expandedWidth * 9 / 16 + 80; // 16:9 aspect ratio + space for buttons
        self.expandedFrame = CGRectMake(
                                        margin,
                                        margin + 10,
                                        expandedWidth,
                                        expandedHeight
                                        );
        
        // Frame for minimized state (AssistiveTouch style)
        CGFloat minimizedSize = 50;
        self.minimizedFrame = CGRectMake(
                                         screenBounds.size.width - minimizedSize - 20,
                                         screenBounds.size.height * 0.4,
                                         minimizedSize,
                                         minimizedSize
                                         );
        
        // Initial state
        self.frame = self.minimizedFrame;
        self.windowState = FloatingWindowStateMinimized;
        
        self.isPreviewActive = NO;
        self.isReceivingFrames = NO;
        self.isSubstitutionActive = NO;
        
        // Setup UI components
        [self setupUI];
        [self setupGestureRecognizers];
        
        // Update appearance for initial state
        [self updateAppearanceForState:self.windowState];
        
        writeLog(@"[FloatingWindow] Initialized in minimized state");
    }
    return self;
}

- (void)dealloc {
    [self stopPreviewUpdateTimer];
}

#pragma mark - UI Setup

- (void)setupUI {
    // Main container
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentView.backgroundColor = [UIColor clearColor];
    [self addSubview:self.contentView];
    
    // Layout for contentView to fill the window
    [NSLayoutConstraint activateConstraints:@[
        [self.contentView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    
    // Setup UI components
    [self setupVideoView];
    [self setupButtons];
    [self setupLoadingIndicator];
    [self setupMinimizedIcon];
}

- (void)setupVideoView {
    // Use RTCMTLVideoView for efficient video rendering
    self.videoView = [[RTCMTLVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    
    // Calcular altura para manter proporção 16:9
    CGFloat videoHeight = self.expandedFrame.size.width * 9.0 / 16.0;
    [NSLayoutConstraint activateConstraints:@[
        [self.videoView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.videoView.heightAnchor constraintEqualToConstant:videoHeight],
    ]];
}

- (void)setupButtons {
    // Container para os botões lado a lado
    UIView *buttonContainer = [[UIView alloc] init];
    buttonContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:buttonContainer];
    
    [NSLayoutConstraint activateConstraints:@[
        [buttonContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [buttonContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
        [buttonContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        [buttonContainer.heightAnchor constraintEqualToConstant:40]
    ]];
    
    // Botão de preview - Inicialmente desabilitado
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor systemBlueColor];
    self.toggleButton.layer.cornerRadius = 10;
    self.toggleButton.enabled = NO; // Inicialmente desabilitado
    self.toggleButton.alpha = 0.5;  // Visual de desabilitado
    [self.toggleButton addTarget:self action:@selector(togglePreview:) forControlEvents:UIControlEventTouchUpInside];
    [buttonContainer addSubview:self.toggleButton];
    
    // Botão de burlador
    self.substitutionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.substitutionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.substitutionButton setTitle:@"Ativar Burlador" forState:UIControlStateNormal];
    [self.substitutionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.substitutionButton.backgroundColor = [UIColor systemBlueColor];
    self.substitutionButton.layer.cornerRadius = 10;
    [self.substitutionButton addTarget:self action:@selector(toggleSubstitution:) forControlEvents:UIControlEventTouchUpInside];
    [buttonContainer addSubview:self.substitutionButton];
    
    // Layout lado a lado
    [NSLayoutConstraint activateConstraints:@[
        [self.toggleButton.leadingAnchor constraintEqualToAnchor:buttonContainer.leadingAnchor],
        [self.toggleButton.topAnchor constraintEqualToAnchor:buttonContainer.topAnchor],
        [self.toggleButton.bottomAnchor constraintEqualToAnchor:buttonContainer.bottomAnchor],
        [self.toggleButton.widthAnchor constraintEqualToConstant:(self.expandedFrame.size.width - 20) * 0.48],
        
        [self.substitutionButton.trailingAnchor constraintEqualToAnchor:buttonContainer.trailingAnchor],
        [self.substitutionButton.topAnchor constraintEqualToAnchor:buttonContainer.topAnchor],
        [self.substitutionButton.bottomAnchor constraintEqualToAnchor:buttonContainer.bottomAnchor],
        [self.substitutionButton.widthAnchor constraintEqualToConstant:(self.expandedFrame.size.width - 20) * 0.48],
    ]];
}

- (void)setupLoadingIndicator {
    // Loading spinner
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
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.videoView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.videoView.centerYAnchor],
    ]];
}

- (void)setupMinimizedIcon {
    // Create icon for minimized state
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor redColor]; // Vermelho por padrão (burlador desativado)
    [self addSubview:self.iconView];
    
    // Center the icon
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:26],
        [self.iconView.heightAnchor constraintEqualToConstant:26]
    ]];
    
    // Set initial icon
    [self updateMinimizedIconWithState];
    
    // Initially hidden until window is minimized
    self.iconView.hidden = YES;
}

- (void)setupGestureRecognizers {
    // Pan gesture for moving the window
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    panGesture.maximumNumberOfTouches = 1;
    panGesture.minimumNumberOfTouches = 1;
    [self addGestureRecognizer:panGesture];
    
    // Tap to expand/minimize
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.numberOfTapsRequired = 1;
    [self addGestureRecognizer:tapGesture];
    
    // Configure dependencies between gestures to avoid conflicts
    [tapGesture requireGestureRecognizerToFail:panGesture];
}

#pragma mark - Preview Update Timer

- (void)startPreviewUpdateTimer {
    [self stopPreviewUpdateTimer];
    
    // Criar um timer que atualiza o preview a cada 1/30 segundos (30fps)
    self.previewUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                              repeats:YES
                                                                block:^(NSTimer * _Nonnull timer) {
        [self updatePreviewFrame];
    }];
}

- (void)stopPreviewUpdateTimer {
    if (self.previewUpdateTimer) {
        [self.previewUpdateTimer invalidate];
        self.previewUpdateTimer = nil;
    }
}

- (void)updatePreviewFrame {
    // Apenas atualiza se o preview estiver ativo
    if (!self.isPreviewActive || !self.webRTCManager || !self.isSubstitutionActive) {
        return;
    }
    
    // Obter um frame do WebRTC para visualização
    CMSampleBufferRef sampleBuffer = [self.webRTCManager getCurrentFrame:NULL forceReNew:NO];
    
    if (sampleBuffer) {
        // Se tiver vídeo e o preview layer estiver pronto para receber mais
        if (self.videoView && self.isPreviewActive) {
            writeLog(@"[FloatingWindow] Frame para preview obtido com sucesso");
        }
        
        // Liberar o buffer após uso
        CFRelease(sampleBuffer);
    } else {
        // MODIFICADO: Reduzir a frequência de logs de erro
        static NSTimeInterval lastLogTime = 0;
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        
        if (currentTime - lastLogTime > 2.0) { // Log a cada 2 segundos em vez de cada frame
            writeLog(@"[FloatingWindow] Não foi possível obter frame para preview");
            lastLogTime = currentTime;
        }
    }
}

#pragma mark - Public Methods

- (void)show {
    // Configure for initial state
    self.frame = self.minimizedFrame;
    self.windowState = FloatingWindowStateMinimized;
    [self updateAppearanceForState:self.windowState];
    
    // Make visible
    self.hidden = NO;
    self.alpha = 0;
    
    // Animate entry
    self.transform = CGAffineTransformMakeScale(0.5, 0.5);
    
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 0.8; // Start with reduced alpha for minimized
    } completion:nil];
    
    [self makeKeyAndVisible];
    writeLog(@"[FloatingWindow] Window shown");
}

- (void)hide {
    // Parar qualquer preview ou substituição
    [self stopPreview];
    
    // Se o burlador estiver ativo, desative-o
    if (self.isSubstitutionActive) {
        [self setSubstitutionActive:NO];
    }
    
    // Animate exit
    [UIView animateWithDuration:0.2 animations:^{
        self.transform = CGAffineTransformMakeScale(0.5, 0.5);
        self.alpha = 0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
    }];
    
    writeLog(@"[FloatingWindow] Window hidden");
}

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        // Verificamos primeiro se o burlador está ativo
        if (!self.isSubstitutionActive) {
            writeLog(@"[FloatingWindow] Não é possível ativar preview sem o burlador ativo");
            return;
        }
        [self startPreview];
    }
}

- (void)toggleSubstitution:(UIButton *)sender {
    if (self.isSubstitutionActive) {
        [self setSubstitutionActive:NO];
    } else {
        [self setSubstitutionActive:YES];
    }
}

- (void)setSubstitutionActive:(BOOL)active {
    // Se não há alteração de estado, retorna
    if (self.isSubstitutionActive == active) return;
    
    self.isSubstitutionActive = active;
    
    if (active) {
        // Ativar burlador
        [self.substitutionButton setTitle:@"Desativar Burlador" forState:UIControlStateNormal];
        self.substitutionButton.backgroundColor = [UIColor redColor];
        
        // Habilitar botão de preview
        self.toggleButton.enabled = YES;
        self.toggleButton.alpha = 1.0;
        
        writeLog(@"[FloatingWindow] Burlador ativado");
        
        // Se WebRTCManager está disponível, ative a substituição
        if (self.webRTCManager) {
            // Redefinir flag de desconexão solicitada pelo usuário
            self.webRTCManager.userRequestedDisconnect = NO;
            
            [self.webRTCManager setSubstitutionActive:YES];
            
            // Se o WebRTC não estiver conectado, inicie a conexão
            if (self.webRTCManager.state == WebRTCManagerStateDisconnected ||
                self.webRTCManager.state == WebRTCManagerStateError) {
                [self.webRTCManager startWebRTC];
            }
        } else {
            writeLog(@"[FloatingWindow] WebRTCManager não inicializado");
        }
    } else {
        // Desativar burlador
        [self.substitutionButton setTitle:@"Ativar Burlador" forState:UIControlStateNormal];
        self.substitutionButton.backgroundColor = [UIColor systemBlueColor];
        
        // Desabilitar botão de preview e parar preview se estiver ativo
        if (self.isPreviewActive) {
            [self stopPreview];
        }
        self.toggleButton.enabled = NO;
        self.toggleButton.alpha = 0.5;
        
        writeLog(@"[FloatingWindow] Burlador desativado");
        
        // Desativar substituição no WebRTCManager e desconectar completamente
        if (self.webRTCManager) {
            [self.webRTCManager setSubstitutionActive:NO];
            
            // Desconectar WebRTC completamente quando o burlador for desativado
            if (self.webRTCManager.state != WebRTCManagerStateDisconnected) {
                // Marcar como solicitação do usuário
                self.webRTCManager.userRequestedDisconnect = YES;
                
                // Enviar bye para desconectar de forma adequada
                [self.webRTCManager sendByeMessage];
                
                // Desativar após pequeno atraso para garantir que a mensagem seja enviada
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self.webRTCManager stopWebRTC:YES];
                });
            }
        }
    }
    
    // Atualizar o ícone na versão minimizada
    [self updateMinimizedIconWithState];
}

- (void)startPreview {
    // Verificar se o WebRTCManager está presente e se o burlador está ativo
    if (!self.webRTCManager) {
        writeLog(@"[FloatingWindow] WebRTCManager não inicializado");
        return;
    }
    
    // Não permitir ativar preview sem o burlador ativo
    if (!self.isSubstitutionActive) {
        writeLog(@"[FloatingWindow] Não é possível ativar preview sem o burlador ativo");
        return;
    }
    
    self.isPreviewActive = YES;
    [self.toggleButton setTitle:@"Desativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor redColor]; // Vermelho quando ativo
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    
    // Verificar se o WebRTC já está conectado
    if (self.webRTCManager.state == WebRTCManagerStateConnected && self.webRTCManager.videoTrack) {
        // Se já estiver conectado, adicionar o videoTrack ao videoView
        [self.webRTCManager.videoTrack addRenderer:self.videoView];
        [self.loadingIndicator stopAnimating];
    } else if (self.webRTCManager.state != WebRTCManagerStateConnecting) {
        // Se não estiver conectado nem conectando, exibir uma mensagem
        writeLog(@"[FloatingWindow] WebRTC não está conectado para mostrar preview");
        // Não fazemos nada aqui, pois quando a conexão for estabelecida,
        // o didReceiveVideoTrack será chamado e atualizará o videoView
    }
    
    // Iniciar timer para atualizar o preview
    [self startPreviewUpdateTimer];
    
    // Expandir se estiver minimizado
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    }
}

- (void)stopPreview {
    if (!self.isPreviewActive) return;
    
    self.isPreviewActive = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor systemBlueColor]; // Azul quando inativo
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    
    // Parar o timer de atualização
    [self stopPreviewUpdateTimer];
    
    // Remover o videoTrack do videoView para parar a exibição do preview
    if (self.webRTCManager && self.webRTCManager.videoTrack) {
        [self.webRTCManager.videoTrack removeRenderer:self.videoView];
    }
    
    // NÃO desconectar WebRTC se o burlador estiver ativo
    // Isso garante que a substituição continue funcionando mesmo sem preview
}

- (void)updateConnectionStatus:(NSString *)status {
    // Atualizar estado visual (cor do ícone quando minimizado)
    [self updateMinimizedIconWithState];
    
    // Verificar se houve erro fatal de conexão
    // Modificado para só desativar o burlador em casos de erros mais severos, não timeouts
    if ([status containsString:@"Erro fatal"] || [status containsString:@"Erro crítico"]) {
        // Em caso de erro fatal, desativar automaticamente o burlador
        if (self.isSubstitutionActive) {
            writeLog(@"[FloatingWindow] Erro fatal de conexão detectado, desativando burlador");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setSubstitutionActive:NO];
            });
        }
    }
    // Para erros de timeout ou conexão, apenas mostrar indicador visual, mas não desativar
    else if ([status containsString:@"Erro"]) {
        writeLog(@"[FloatingWindow] Erro de conexão detectado, tentando recuperar...");
        // Atualiza apenas UI, não desativa burlador
    }
}

#pragma mark - WebRTCManagerDelegate

- (void)didUpdateConnectionStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateConnectionStatus:status];
    });
}

- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack {
    dispatch_async(dispatch_get_main_queue(), ^{
        writeLog(@"[FloatingWindow] Recebido videoTrack do WebRTC");
        
        // Adicionar o videoTrack ao videoView APENAS se o preview estiver ativo
        if (self.videoView && self.isPreviewActive) {
            [videoTrack addRenderer:self.videoView];
            writeLog(@"[FloatingWindow] VideoTrack adicionado ao videoView");
        }
        
        // Parar indicador de carregamento
        [self.loadingIndicator stopAnimating];
        
        // Atualizar estado
        self.isReceivingFrames = YES;
    });
}

- (void)didChangeConnectionState:(WebRTCManagerState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Atualizar UI baseado no estado da conexão
        switch (state) {
            case WebRTCManagerStateConnecting:
                [self.loadingIndicator startAnimating];
                break;
                
            case WebRTCManagerStateConnected:
                // Expandir se estiver minimizado e o preview estiver ativo
                if (self.windowState == FloatingWindowStateMinimized && self.isPreviewActive) {
                    [self setWindowState:FloatingWindowStateExpanded];
                }
                [self.loadingIndicator stopAnimating];
                break;
                
            case WebRTCManagerStateError:
                self.isReceivingFrames = NO;
                [self.loadingIndicator stopAnimating];
                
                // Se o preview estiver ativo, desativá-lo
                if (self.isPreviewActive) {
                    self.isPreviewActive = NO;
                    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
                    self.toggleButton.backgroundColor = [UIColor systemBlueColor];
                    [self stopPreviewUpdateTimer];
                }
                
                // MODIFICADO: Não desativar o burlador automaticamente em erros,
                // pois pode ser apenas um timeout temporário. O WebRTCManager tentará reconectar.
                // Apenas apresentar feedback visual.
                break;
                
            case WebRTCManagerStateDisconnected:
                self.isReceivingFrames = NO;
                [self.loadingIndicator stopAnimating];
                
                // Se o preview estiver ativo, desativá-lo
                if (self.isPreviewActive) {
                    self.isPreviewActive = NO;
                    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
                    self.toggleButton.backgroundColor = [UIColor systemBlueColor];
                    [self stopPreviewUpdateTimer];
                }
                
                // Se for desconexão explícita (não temporária), desativar burlador
                if (self.isSubstitutionActive && self.webRTCManager.userRequestedDisconnect) {
                    [self setSubstitutionActive:NO];
                }
                break;
                
            default:
                break;
        }
        
        // Atualizar ícone minimizado
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
    // Determine and apply the appearance based on state
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
    // Se o preview estiver ativo, desativá-lo ao minimizar
    if (self.isPreviewActive) {
        [self stopPreview];
    }
    
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
        
        // Esconder elementos UI
        self.toggleButton.alpha = 0;
        self.substitutionButton.alpha = 0;
        self.videoView.alpha = 0;
        
        // Fundo escuro sempre
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
    } completion:^(BOOL finished) {
        // Confirmar que elementos estão escondidos
        self.toggleButton.hidden = YES;
        self.substitutionButton.hidden = YES;
        self.videoView.hidden = YES;
    }];
}

- (void)animateToExpandedState {
    // Preparar para expandir
    self.toggleButton.hidden = NO;
    self.substitutionButton.hidden = NO;
    self.videoView.hidden = NO;
    
    // Esconder o ícone minimizado
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
        
        // Mostrar elementos UI
        self.toggleButton.alpha = 1.0;
        self.substitutionButton.alpha = 1.0;
        self.videoView.alpha = 1.0;
        
        // Fundo escuro
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
    } completion:nil];
}

- (void)updateMinimizedIconWithState {
    UIImage *image = nil;
    
    // A cor e ícone mudam baseado apenas no estado do burlador, não do preview
    if (@available(iOS 13.0, *)) {
        if (self.isSubstitutionActive) {
            // Câmera com cor verde quando burlador ativo
            image = [UIImage systemImageNamed:@"video.fill"];
            self.iconView.tintColor = [UIColor greenColor];
        } else {
            // Câmera com slash e cor vermelha quando burlador desativado
            image = [UIImage systemImageNamed:@"video.slash"];
            self.iconView.tintColor = [UIColor redColor];
        }
    }
    
    if (!image) {
        // Fallback para iOS < 13
        CGSize iconSize = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(iconSize, NO, 0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) {
            CGContextSetFillColorWithColor(context,
                self.isSubstitutionActive ? [UIColor greenColor].CGColor : [UIColor redColor].CGColor);
            CGContextFillEllipseInRect(context, CGRectMake(0, 0, iconSize.width, iconSize.height));
            image = UIGraphicsGetImageFromCurrentImageContext();
        }
        UIGraphicsEndImageContext();
    }
    
    self.iconView.image = image;
}

#pragma mark - Gesture Handlers

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.lastPosition = self.center;
        self.isDragging = YES;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.lastPosition.x + translation.x, self.lastPosition.y + translation.y);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        self.isDragging = NO;
        if (self.windowState == FloatingWindowStateMinimized) {
            [self snapToEdgeIfNeeded];
        }
    }
}

- (void)snapToEdgeIfNeeded {
    // Implement snap to edge when minimized
    if (self.windowState != FloatingWindowStateMinimized) return;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGPoint center = self.center;
    CGFloat padding = 10;
    
    // Decide which edge to snap to (right or left)
    if (center.x < screenBounds.size.width / 2) {
        // Snap to left edge
        center.x = self.frame.size.width / 2 + padding;
    } else {
        // Snap to right edge
        center.x = screenBounds.size.width - self.frame.size.width / 2 - padding;
    }
    
    // Animate the movement
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.center = center;
    } completion:^(BOOL finished) {
        // Update the minimized frame
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
        // Verificar se tocou em algum dos botões
        CGPoint location = [gesture locationInView:self];
        CGPoint pointInToggleButton = [self.toggleButton convertPoint:location fromView:self];
        CGPoint pointInSubstitutionButton = [self.substitutionButton convertPoint:location fromView:self];
        
        if (![self.toggleButton pointInside:pointInToggleButton withEvent:nil] &&
            ![self.substitutionButton pointInside:pointInSubstitutionButton withEvent:nil]) {
            [self setWindowState:FloatingWindowStateMinimized];
        }
    }
}

#pragma mark - RTCVideoViewDelegate

- (void)videoView:(RTCMTLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    // Update frame size record
    self.lastFrameSize = size;
    
    // Mark as receiving frames only if dimensions are valid
    if (size.width > 0 && size.height > 0) {
        self.isReceivingFrames = YES;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Stop loading indicator
            [self.loadingIndicator stopAnimating];
            
            // Update minimized icon state
            [self updateMinimizedIconWithState];
        });
    }
}

@end
