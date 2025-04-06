,ma#import "FloatingWindow.h"
#import "logger.h"
#import "FrameBridge.h"

// Variável estática para armazenar a instância atual
static FloatingWindow *currentWindow = nil;

@implementation FloatingWindow

#pragma mark - Lifecycle Management

// Método para criar e mostrar a janela
+ (void)showWithWebRTCManager:(WebRTCManager *)manager {
    // Verificar se o FrameBridge está ativo
    if (!isFrameBridgeActive()) {
        writeLog(@"[FloatingWindow] Não é possível mostrar preview: FrameBridge não está ativo");
        
        // Mostrar um alerta para informar o usuário
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Preview Indisponível"
            message:@"O stream WebRTC não está ativo. Ative-o primeiro."
            preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        
        [[UIApplication sharedApplication].keyWindow.rootViewController
            presentViewController:alert animated:YES completion:nil];
        
        return;
    }
    
    // Se já existe uma janela, destruí-la primeiro
    if (currentWindow != nil) {
        [self destroy];
    }
    
    // Criar nova instância
    currentWindow = [[FloatingWindow alloc] init];
    currentWindow.webRTCManager = manager;
    
    // Configurar e mostrar a janela
    [currentWindow setupUI];
    [currentWindow makeKeyAndVisible];
    
    // Conectar ao video track se disponível
    if (manager.lastReceivedTrack) {
        [manager.lastReceivedTrack addRenderer:currentWindow.videoView];
        writeLog(@"[FloatingWindow] Preview conectado ao video track");
    } else {
        writeLog(@"[FloatingWindow] Nenhum video track disponível para preview");
    }
}

// Método para destruir a janela completamente
+ (void)destroy {
    if (currentWindow) {
        // Remover o renderer para liberar recursos
        if (currentWindow.webRTCManager.lastReceivedTrack) {
            [currentWindow.webRTCManager.lastReceivedTrack removeRenderer:currentWindow.videoView];
        }
        
        // Esconder a janela
        currentWindow.hidden = YES;
        
        // Liberar referências
        [currentWindow releaseReferences];
        
        // Zerar a referência estática
        currentWindow = nil;
        
        writeLog(@"[FloatingWindow] Janela de preview destruída");
    }
}

// Liberar todas as referências internas
- (void)releaseReferences {
    self.videoView = nil;
    self.closeButton = nil;
    self.webRTCManager = nil;
}

#pragma mark - Initialization

- (instancetype)init {
    // Como você só usa iOS 15+, pode usar diretamente a windowScene
    UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        self = [super initWithWindowScene:(UIWindowScene *)scene];
    } else {
        self = [super init]; // Fallback caso algo dê errado
    }
    
    if (self) {
        // Configuração básica da janela
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9];
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        
        // Configuração de sombra
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 4);
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 8;
        
        // Configuração de tamanho e posição
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        CGFloat width = 270;
        CGFloat height = 200;
        
        self.frame = CGRectMake(
            (screenBounds.size.width - width) / 2,  // Centralizado horizontalmente
            80,                                     // Um pouco abaixo do topo
            width,
            height
        );
        
        writeLog(@"[FloatingWindow] Janela de preview inicializada");
    }
    return self;
}

#pragma mark - UI Setup

- (void)setupUI {
    // View de vídeo - ocupa quase toda a janela
    self.videoView = [[RTCMTLVideoView alloc] initWithFrame:CGRectMake(10, 10, self.frame.size.width - 20, self.frame.size.height - 50)];
    self.videoView.backgroundColor = [UIColor blackColor];
    [self addSubview:self.videoView];
    
    // Botão de fechar - simples, na parte inferior
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.frame = CGRectMake(self.frame.size.width/2 - 40, self.frame.size.height - 35, 80, 25);
    [self.closeButton setTitle:@"Fechar" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.backgroundColor = [UIColor colorWithRed:0.7 green:0.1 blue:0.1 alpha:0.8];
    self.closeButton.layer.cornerRadius = 8;
    [self.closeButton addTarget:self action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.closeButton];
    
    // Adicionar gesto para arrastar a janela
    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:panGesture];
}

#pragma mark - Actions

- (void)closeButtonTapped {
    writeLog(@"[FloatingWindow] Botão de fechar pressionado");
    [FloatingWindow destroy];
}

#pragma mark - Gesture Handling

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        [gesture setTranslation:CGPointZero inView:self];
    }
}

@end
