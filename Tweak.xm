#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"

#import <objc/runtime.h>

static char kFloatingWindowKey;

// Função para acessar a janela flutuante de qualquer contexto
FloatingWindow *getSharedFloatingWindow(void) {
    return objc_getAssociatedObject([UIApplication sharedApplication], &kFloatingWindowKey);
}

// Função para definir a janela flutuante compartilhada
void setSharedFloatingWindow(FloatingWindow *window) {
    objc_setAssociatedObject([UIApplication sharedApplication], &kFloatingWindowKey, window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static FloatingWindow *floatingWindow;

// Camadas para substituição visual
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;

// Hooks para substituição de câmera

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer {
    writeLog(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer: %@", layer);
    %orig;

    // Configurar display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        
        // Ajusta a taxa de frames baseado no dispositivo
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 30; // 30 FPS para economia de bateria
        } else {
            displayLink.frameInterval = 2; // Aproximadamente 30 FPS em dispositivos mais antigos
        }
        
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        writeLog(@"DisplayLink criado para atualização contínua");
    }

    // Adiciona camada de preview se ainda não existe
    if (![[self sublayers] containsObject:g_previewLayer]) {
        writeLog(@"Configurando camadas de preview");
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0.0; // Inicia invisível
        
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        g_previewLayer.opacity = 0.0; // Inicia invisível

        // Inicializa tamanho das camadas na thread principal
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
            writeLog(@"Tamanho das camadas inicializado: %@", NSStringFromCGRect(self.bounds));
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender {
    // Obter a janela flutuante compartilhada
    FloatingWindow *sharedFloatingWindow = getSharedFloatingWindow();
    
    // Verificação para depuração
    static NSTimeInterval lastLogTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (currentTime - lastLogTime > 3.0) { // Log a cada 3 segundos
        writeLog(@"Step: floatingWindow=%@, webRTCManager=%@, isSubstitutionActive=%d",
                 sharedFloatingWindow ? @"sim" : @"não",
                 sharedFloatingWindow.webRTCManager ? @"sim" : @"não",
                 sharedFloatingWindow.webRTCManager ? (sharedFloatingWindow.webRTCManager.isSubstitutionActive ? 1 : 0) : -1);
        lastLogTime = currentTime;
    }
    
    // Verificações iniciais
    if (!sharedFloatingWindow || !sharedFloatingWindow.webRTCManager) {
        // Garantir que as camadas estejam ocultas
        if (g_maskLayer != nil) g_maskLayer.opacity = 0.0;
        if (g_previewLayer != nil) g_previewLayer.opacity = 0.0;
        return;
    }
    
    // Verificar se burlador está ativo
    BOOL burlarAtivo = sharedFloatingWindow.webRTCManager.isSubstitutionActive;
    
    // Controla a visibilidade das camadas baseado no estado do burlador
    if (!burlarAtivo) {
        // Esconder camadas imediatamente se burlador está desativado
        if (g_maskLayer != nil) g_maskLayer.opacity = 0.0;
        if (g_previewLayer != nil) g_previewLayer.opacity = 0.0;
        return;
    }
    
    // Se chegou aqui, o burlador está ativo
    
    // Mostrar camadas imediatamente
    if (g_maskLayer != nil) {
        g_maskLayer.opacity = 1.0;
        writeLog(@"Camada preta agora visível, opacidade=%.1f", g_maskLayer.opacity);
    }
    
    if (g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview se necessário
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
            writeLog(@"Atualizando tamanho das camadas: %@", NSStringFromCGRect(self.bounds));
        }
        
        // Configura o comportamento de escala do vídeo para corresponder ao layer original
        [g_previewLayer setVideoGravity:[self videoGravity]];
        
        // Mostra a camada
        g_previewLayer.opacity = 1.0;
        writeLog(@"Camada preview agora visível, opacidade=%.1f", g_previewLayer.opacity);
        
        // Tentar obter frame para preview apenas se estiver pronto para receber mais dados
        if (g_previewLayer.readyForMoreMediaData) {
            // Obtém o próximo frame
            CMSampleBufferRef newBuffer = [floatingWindow.webRTCManager getCurrentFrame:nil forceReNew:YES];
            if (newBuffer != nil) {
                // Limpa quaisquer frames na fila
                [g_previewLayer flush];
                
                // Adiciona o frame à camada de preview
                [g_previewLayer enqueueSampleBuffer:newBuffer];
                
                // Verificar se o status do display layer tem algum erro
                if (g_previewLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                    NSError *error = g_previewLayer.error;
                    writeLog(@"Erro no AVSampleBufferDisplayLayer: %@", error);
                    
                    // Tentar resetar o display layer
                    [g_previewLayer flush];
                }
                
                // Log ocasional para confirmar que frames estão sendo adicionados
                static int frameCount = 0;
                if (++frameCount % 30 == 0) { // Log a cada 30 frames
                    writeLog(@"Frame adicionado ao AVSampleBufferDisplayLayer");
                }
                
                // Liberar o buffer
                CFRelease(newBuffer);
            } else {
                // Log ocasional para evitar spam
                static NSTimeInterval lastFrameLogTime = 0;
                if (currentTime - lastFrameLogTime > 2.0) { // Log a cada 2 segundos
                    writeLog(@"Não foi possível obter frame para AVSampleBufferDisplayLayer");
                    lastFrameLogTime = currentTime;
                }
            }
        }
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    writeLog(@"AVCaptureSession::startRunning - Câmera iniciando");
    %orig;
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    writeLog(@"AVCaptureSession::stopRunning - Câmera parando");
    %orig;
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    writeLog(@"AVCaptureSession::addInput - Adicionando dispositivo: %@", [input device]);
    %orig;
}

// Método chamado quando um dispositivo de saída é adicionado à sessão
- (void)addOutput:(AVCaptureOutput *)output{
    writeLog(@"AVCaptureSession::addOutput - Adicionando output: %@", output);
    
    // Se for AVCaptureVideoDataOutput, vamos interceptar seu delegate
    if ([output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")]) {
        writeLog(@"Detectado AVCaptureVideoDataOutput para interceptação");
    }
    
    %orig;
}
%end

// Hook para interceptação do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    writeLog(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Delegate: %@, Queue: %@", sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        writeLog(@"Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if (![hooked containsObject:className]) {
        writeLog(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Verifica as configurações de vídeo
        NSDictionary *settings = [self videoSettings];
        writeLog(@"Configurações de vídeo: %@", settings);
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Verificar se temos WebRTCManager e se burlador está ativo
                if (floatingWindow && floatingWindow.webRTCManager && floatingWindow.webRTCManager.isSubstitutionActive) {
                    // Log ocasional para evitar spam
                    static int frameCount = 0;
                    if (++frameCount % 300 == 0) { // Log a cada 300 frames
                        writeLog(@"Interceptando frame da câmera para substituição");
                    }
                    
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef newBuffer = [floatingWindow.webRTCManager getCurrentFrame:sampleBuffer forceReNew:NO];
                    
                    // Atualiza o preview usando o buffer
                    if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                    }
                    
                    // Chama o método original com o buffer substituído
                    CMSampleBufferRef bufferToUse = newBuffer != nil ? newBuffer : sampleBuffer;
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, bufferToUse, connection);
                }
                
                // Se não há substituição ativa, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        floatingWindow = [[FloatingWindow alloc] init];
        WebRTCManager *manager = [[WebRTCManager alloc] initWithDelegate:floatingWindow];
        floatingWindow.webRTCManager = manager;
        
        // Salvar a janela flutuante para acesso global
        setSharedFloatingWindow(floatingWindow);
        
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}
%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    if (floatingWindow) {
        [floatingWindow hide];
    }
    floatingWindow = nil;
}
