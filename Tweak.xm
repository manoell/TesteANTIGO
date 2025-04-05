#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "FrameBridge.h"
#import <UIKit/UIKit.h>
#import "logger.h"

// Instâncias globais
static FloatingWindow *floatingWindow;
static WebRTCManager *webRTCManager;
static FrameBridge *frameBridge;

// Variáveis para o hook de AVCaptureVideoDataOutput
static NSMutableArray *hookedClasses;

// Declarações de hooks
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow e WebRTCManager");
        
        // Inicializar FrameBridge (deveria ser feito antes do WebRTCManager)
        frameBridge = [FrameBridge sharedInstance];
        
        // Inicializar FloatingWindow
        floatingWindow = [[FloatingWindow alloc] init];
        
        // Inicializar WebRTCManager
        webRTCManager = [[WebRTCManager alloc] initWithDelegate:floatingWindow];
        floatingWindow.webRTCManager = webRTCManager;
        
        // Mostrar a janela flutuante
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}

%end

// Hook para AVCaptureVideoDataOutput para interceptar o fluxo de vídeo
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    writeLog(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Delegate: %@, Queue: %@", sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        writeLog(@"Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hookedClasses = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if (![hookedClasses containsObject:className]) {
        writeLog(@"Hooking nova classe de delegate: %@", className);
        [hookedClasses addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Verifica as configurações de vídeo
        writeLog(@"Configurações de vídeo: %@", [self videoSettings]);
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                
                // Verifica se o FrameBridge está ativo (recebendo frames do WebRTC)
                if ([FrameBridge sharedInstance].isActive) {
                    writeLog(@"AVCaptureOutput - Substituindo buffer com frame do WebRTC");
                    
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef newBuffer = [[FrameBridge sharedInstance] getCurrentFrame:sampleBuffer forceReNew:NO];
                    
                    // Chama o método original com o buffer substituído se disponível
                    if (newBuffer != nil) {
                        return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer, connection);
                    }
                    
                    writeLog(@"AVCaptureOutput - Frame do WebRTC não disponível, usando buffer original");
                }
                
                // Se não temos um frame do WebRTC, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}

%end

// Hook para AVCaptureVideoPreviewLayer para substituir o preview
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    writeLog(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer: %@", layer);
    %orig;
    
    // Configurar display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updatePreview:)];
        
        // Ajusta a taxa de frames baseado no dispositivo
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 30; // 30 FPS para economia de bateria
        } else {
            displayLink.frameInterval = 2; // Aproximadamente 30 FPS em dispositivos mais antigos
        }
        
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        writeLog(@"DisplayLink criado para atualização contínua do preview");
    }
}

// Método adicionado para atualização contínua do preview
%new
- (void)updatePreview:(CADisplayLink *)displayLink {
    // Verifica se o FrameBridge está ativo
    if ([FrameBridge sharedInstance].isActive) {
        writeLog(@"AVCaptureVideoPreviewLayer - Atualizando preview com frame do WebRTC");
        
        // TODO: Implementar substituição visual do preview usando FrameBridge
        // Esta parte seria uma implementação semelhante ao que você já tem no seu código
        // para substituir o preview com uma camada contendo o frame do WebRTC
    }
}

%end

// Função chamada quando o tweak é carregado
%ctor {
    writeLog(@"--------------------------------------------------");
    writeLog(@"WebRTC-VCAM - Inicializando tweak");
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    
    // Inicializa recursos globais
    hookedClasses = nil;
    writeLog(@"WebRTC-VCAM inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    writeLog(@"WebRTC-VCAM - Finalizando tweak");
    
    // Limpa recursos globais
    if (floatingWindow) {
        [floatingWindow hide];
    }
    floatingWindow = nil;
    
    if (webRTCManager) {
        [webRTCManager stopWebRTC:YES];
    }
    webRTCManager = nil;
    
    if (frameBridge) {
        [frameBridge releaseResources];
    }
    frameBridge = nil;
    
    hookedClasses = nil;
    
    writeLog(@"WebRTC-VCAM finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
