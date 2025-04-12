#import "FloatingWindow.h"
#import "logger.h"
#import "DarwinNotifications.h"

@interface FloatingWindow ()

// Main UI Components
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong, readwrite) RTCMTLVideoView *videoView;
@property (nonatomic, strong) UIImageView *iconView;

// State tracking
@property (nonatomic, assign) CGPoint lastPosition;
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
        CGFloat expandedHeight = expandedWidth * 9 / 16 + 80; // Seu valor atual
        CGFloat xPosition = margin;
        CGFloat yPosition = (screenBounds.size.height - expandedHeight) / 2; // Centralizar verticalmente
        _expandedFrame = CGRectMake(
                                     xPosition,
                                     yPosition,
                                     expandedWidth,
                                     expandedHeight
                                     );
        
        // Frame for minimized state (AssistiveTouch style)
        CGFloat minimizedSize = 50;
        _minimizedFrame = CGRectMake(
                                         screenBounds.size.width - minimizedSize - 20,
                                         screenBounds.size.height * 0.4,
                                         minimizedSize,
                                         minimizedSize
                                         );
        
        // Initial state
        self.frame = _minimizedFrame;
        _windowState = FloatingWindowStateMinimized;
        
        _isPreviewActive = NO;
        _isReceivingFrames = NO;
        _isSubstitutionActive = NO;
        
        // Setup UI components
        [self setupUI];
        [self setupGestureRecognizers];
        
        // Update appearance for initial state
        [self updateAppearanceForState:_windowState];
        
        writeLog(@"[FloatingWindow] Initialized in minimized state");
    }
    return self;
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
    // Use RTCMTLVideoView for WebRTC video rendering
    self.videoView = [[RTCMTLVideoView alloc] init];
    self.videoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.videoView.delegate = self;
    self.videoView.backgroundColor = [UIColor blackColor];
    [self.contentView addSubview:self.videoView];
    
    // Calcular altura para manter proporção 16:9
    CGFloat videoHeight = (self.expandedFrame.size.width * 9.0 / 16.0) + 20;
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
    self.toggleButton.enabled = NO;
    self.toggleButton.alpha = 0.5;
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
    // Stop preview if active
    if (self.isPreviewActive) {
        [self stopPreview];
    }
    
    // Set substitution inactive
    if (self.isSubstitutionActive) {
        // Use toggleSubstitution to properly handle the state change
        [self toggleSubstitution:nil];
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

- (void)updateConnectionStatus:(NSString *)status {
    writeLog(@"[FloatingWindow] Connection status: %@", status);
    
    // Update UI based on connection status
    dispatch_async(dispatch_get_main_queue(), ^{
        // For serious error messages, consider showing an alert
        if ([status containsString:@"Erro"] || [status containsString:@"falha"]) {
            UIAlertController *alert = [UIAlertController
                                       alertControllerWithTitle:@"Erro de Conexão"
                                       message:status
                                       preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            
            UIViewController *rootVC = self.rootViewController;
            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        }
        
        // Update minimized icon state if needed
        [self updateMinimizedIconWithState];
    });
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

#pragma mark - Preview Methods

- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        [self startPreview];
    }
}

- (void)startPreview {
    // Verificar se o burlador está ativo
    if (!self.isSubstitutionActive) {
        writeLog(@"[FloatingWindow] Não é possível ativar preview sem o burlador ativo");
        return;
    }
    
    self.isPreviewActive = YES;
    [self.toggleButton setTitle:@"Desativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor redColor]; // Vermelho quando ativo
    
    // Mostrar indicador de carregamento
    [self.loadingIndicator startAnimating];
    
    // Expandir se estiver minimizado
    if (self.windowState == FloatingWindowStateMinimized) {
        [self setWindowState:FloatingWindowStateExpanded];
    }
    
    // Parar indicador de carregamento quando o preview estiver ativo
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.loadingIndicator stopAnimating];
    });
    
    writeLog(@"[FloatingWindow] Preview ativado");
}

- (void)stopPreview {
    if (!self.isPreviewActive) return;
    
    self.isPreviewActive = NO;
    [self.toggleButton setTitle:@"Ativar Preview" forState:UIControlStateNormal];
    self.toggleButton.backgroundColor = [UIColor systemBlueColor]; // Azul quando inativo
    
    // Parar indicador de carregamento
    [self.loadingIndicator stopAnimating];
    
    writeLog(@"[FloatingWindow] Preview desativado");
}

// Este método é chamado pelo WebRTCFrameProvider quando recebe uma nova faixa de vídeo
- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack {
    writeLog(@"[FloatingWindow] Faixa de vídeo recebida");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Configurar o videoView se existir
        if (self.videoView) {
            // Adicionar o renderer para o videoView
            [videoTrack addRenderer:self.videoView];
        }
        
        // Marcar que estamos recebendo frames
        self.isReceivingFrames = YES;
        
        // Parar indicador de carregamento
        [self.loadingIndicator stopAnimating];
        
        // Atualizar ícone minimizado
        [self updateMinimizedIconWithState];
    });
}

@end
