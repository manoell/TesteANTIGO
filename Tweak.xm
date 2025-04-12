#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "DarwinNotifications.h"

#import <objc/runtime.h>

// Variável global para a instância de FloatingWindow
static FloatingWindow *g_floatingWindow = nil;

// Camadas para substituição visual
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;

// Variáveis globais adaptadas do baseSubstituicao.txt
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait;

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
// Baseado no código de referência do baseSubstituicao.txt
%new
-(void)step:(CADisplayLink *)sender {
    // Verificar estado do burlador via Darwin Notifications
    BOOL isSubstitutionActive = isBurladorActive();
    
    // Cache de verificação para evitar sobrecarga
    static NSTimeInterval lastLogTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (currentTime - lastLogTime > 3.0) { // Log a cada 3 segundos
        writeLog(@"[step] Estado burlador: %@, camadas: mask=%@, preview=%@",
                isSubstitutionActive ? @"ATIVO" : @"INATIVO",
                g_maskLayer ? @"OK" : @"NULL",
                g_previewLayer ? @"OK" : @"NULL");
        lastLogTime = currentTime;
    }
    
    // Controla a visibilidade das camadas baseado no estado do burlador
    if (!isSubstitutionActive) {
        // Esconder camadas imediatamente se burlador está desativado
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = 0.0;
            writeLog(@"[step] Ocultando camada de máscara");
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = 0.0;
            writeLog(@"[step] Ocultando camada de preview");
        }
        return;
    }
    
    // Se chegou aqui, o burlador está ativo
    
    // Mostrar camadas para substituição
    if (g_maskLayer != nil) {
        if (g_maskLayer.opacity < 1.0) {
            g_maskLayer.opacity = 1.0;
            writeLog(@"[step] Camada preta agora visível");
        }
    }
    
    if (g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview se necessário
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
            writeLog(@"[step] Tamanho das camadas atualizado: %@", NSStringFromCGRect(self.bounds));
        }
        
        // Configura o comportamento de escala do vídeo para corresponder ao layer original
        [g_previewLayer setVideoGravity:[self videoGravity]];
        
        // Mostra a camada imediatamente
        if (g_previewLayer.opacity < 1.0) {
            g_previewLayer.opacity = 1.0;
            writeLog(@"[step] Camada preview agora visível");
        }
        
        // Aplica rotação apenas se a orientação mudou, como no original
        if (g_photoOrientation != g_lastOrientation) {
            g_lastOrientation = g_photoOrientation;
            
            switch(g_photoOrientation) {
                case AVCaptureVideoOrientationPortrait:
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                    break;
                default:
                    g_previewLayer.transform = self.transform;
            }
            
            writeLog(@"[step] Orientação atualizada: %d", (int)g_photoOrientation);
        }
        
        // Verificações para debug
        static NSTimeInterval lastFrameDebugTime = 0;
        if (currentTime - lastFrameDebugTime > 5.0) { // A cada 5 segundos
            writeLog(@"[step] Status da camada: ready=%d, estado=%d, erro=%@",
                     g_previewLayer.readyForMoreMediaData ? 1 : 0,
                     (int)g_previewLayer.status,
                     g_previewLayer.error ? [g_previewLayer.error localizedDescription] : @"nenhum");
            lastFrameDebugTime = currentTime;
        }
        
        // Tentar obter frame para preview apenas se estiver pronto para receber mais dados
        if (g_previewLayer.readyForMoreMediaData) {
            // Despachar para a thread principal
            dispatch_async(dispatch_get_main_queue(), ^{
                // Obtém o próximo frame na thread principal
                CMSampleBufferRef newBuffer = NULL;
                
                if (g_floatingWindow && g_floatingWindow.webRTCManager) {
                    writeLog(@"[step] Obtendo frame na thread principal");
                    newBuffer = [g_floatingWindow.webRTCManager getCurrentFrame:nil forceReNew:YES];
                    
                    if (newBuffer != nil) {
                        writeLog(@"[step] Frame obtido com sucesso na thread principal");
                        // Voltar para a thread original para atualizar UI
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            [g_previewLayer flush];
                            [g_previewLayer enqueueSampleBuffer:newBuffer];
                            CFRelease(newBuffer);
                            
                            static int frameCount = 0;
                            if (++frameCount % 100 == 0) {
                                writeLog(@"[step] Frame #%d adicionado na thread principal", frameCount);
                            }
                        });
                    } else {
                        writeLog(@"[step] Falha ao obter frame mesmo na thread principal");
                    }
                }
            });
            // Obtém o próximo frame
            CMSampleBufferRef newBuffer = NULL;
            
            // Tenta obter frame
            if (g_floatingWindow && g_floatingWindow.webRTCManager) {
                // Tente com ambos os parâmetros como nil e false para ver se faz diferença
                newBuffer = [g_floatingWindow.webRTCManager getCurrentFrame:nil forceReNew:NO];
                
                if (!newBuffer) {
                    writeLog(@"[step] Primeira tentativa falhou, tentando com forceReNew:YES");
                    newBuffer = [g_floatingWindow.webRTCManager getCurrentFrame:nil forceReNew:YES];
                }
            }
            
            // Log do resultado
            static int frameAttempt = 0;
            if (++frameAttempt % 30 == 0) { // A cada 30 tentativas
                writeLog(@"[step] Tentativa #%d de obter frame: %@",
                         frameAttempt,
                         newBuffer ? @"SUCESSO" : @"FALHA");
            }
            
            // Se obteve um buffer válido, adicionar à camada de preview
            if (newBuffer != nil) {
                // Limpa quaisquer frames na fila
                [g_previewLayer flush];
                
                // Adiciona o frame à camada de preview
                [g_previewLayer enqueueSampleBuffer:newBuffer];
                
                // Verificar se o status do display layer tem algum erro
                BOOL hasError = (g_previewLayer.status == AVQueuedSampleBufferRenderingStatusFailed);
                if (hasError) {
                    NSError *error = g_previewLayer.error;
                    writeLog(@"[step] Erro no AVSampleBufferDisplayLayer: %@", error);
                    
                    // Tentar resetar o display layer
                    [g_previewLayer flush];
                }
                
                // Log ocasional para confirmar que frames estão sendo adicionados
                static int frameCount = 0;
                if (++frameCount % 100 == 0) { // Log a cada 100 frames
                    writeLog(@"[step] Frame #%d adicionado", frameCount);
                }
                
                // Liberar o buffer
                CFRelease(newBuffer);
            } else {
                // Log ocasional para evitar spam
                static NSTimeInterval lastFrameFailTime = 0;
                if (currentTime - lastFrameFailTime > 2.0) { // Log a cada 2 segundos
                    writeLog(@"[step] Não foi possível obter frame para AVSampleBufferDisplayLayer");
                    lastFrameFailTime = currentTime;
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
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
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
        
        // Hook do método de recebimento de frames adaptado do baseSubstituicao.txt
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Verificação CRUCIAL: Obter o status do burlador via Darwin Notifications
                BOOL isSubstitutionActive = isBurladorActive();
                
                // Atualiza orientação para uso no step:
                g_photoOrientation = [connection videoOrientation];
                
                // Log ocasional
                static int callCount = 0;
                if (++callCount % 300 == 0) {
                    writeLog(@"[captureOutput] Frame #%d, substituição: %@, orientação: %d",
                            callCount,
                            isSubstitutionActive ? @"ATIVA" : @"INATIVA",
                            (int)g_photoOrientation);
                }
                
                // Verificar se temos WebRTCManager e se burlador está ativo
                if (isSubstitutionActive) {
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef newBuffer = NULL;
                    
                    if (g_floatingWindow && g_floatingWindow.webRTCManager) {
                        newBuffer = [g_floatingWindow.webRTCManager getCurrentFrame:sampleBuffer forceReNew:NO];
                    }
                    
                    // Atualiza o preview usando o buffer obtido
                    if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                        
                        // Log detalhado a cada 300 frames
                        if (callCount % 300 == 0) {
                            writeLog(@"[captureOutput] Preview atualizado com frame");
                        }
                    }
                    
                    // Chama o método original com o buffer substituído
                    CMSampleBufferRef bufferToUse = newBuffer != nil ? newBuffer : sampleBuffer;
                    
                    // Log detalhado a cada 300 frames
                    if (callCount % 300 == 0) {
                        writeLog(@"[captureOutput] Substituição de buffer: %@", newBuffer != nil ? @"SIM" : @"NÃO");
                    }
                    
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

// Hook no SpringBoard para inicializar o tweak
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    
    // Inicializar o sistema de Darwin Notifications
    registerBurladorActive(NO); // Inicialmente desativado
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Criar a janela flutuante
        g_floatingWindow = [[FloatingWindow alloc] init];
        WebRTCManager *manager = [[WebRTCManager alloc] initWithDelegate:g_floatingWindow];
        g_floatingWindow.webRTCManager = manager;
        
        [g_floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}
%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    registerBurladorActive(NO); // Garantir que o estado é resetado
    if (g_floatingWindow) {
        [g_floatingWindow hide];
        g_floatingWindow = nil;
    }
}
