#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import "FrameBridge.h"
#import "logger.h"

// Variáveis globais para gerenciamento de recursos
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // Timestamp da última atualização por VideoDataOutput
static BOOL g_cameraRunning = NO;                          // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B";                  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait; // Última orientação para otimização

// Instâncias globais
static WebRTCManager *webRTCManager;
static FrameBridge *frameBridge;

// Elementos de UI para visualização
static CALayer *g_maskLayer = nil;

// Variáveis para controle
static NSMutableArray *hookedClasses;

// Variáveis para atalho de volume
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    writeLog(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer: %@", layer);
    %orig;

    // Configura display link para atualização contínua
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
        g_maskLayer.opacity = 0; // Começa invisível
        
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        g_previewLayer.opacity = 0; // Começa invisível

        // Inicializa tamanho das camadas na thread principal
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            writeLog(@"Tamanho das camadas inicializado: %@",
                    NSStringFromCGRect([UIApplication sharedApplication].keyWindow.bounds));
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender{
    // Controla a visibilidade das camadas baseado na atividade do FrameBridge
    // Uso da função global em vez do acesso à propriedade
    BOOL frameBridgeActive = isFrameBridgeActive();
    if (frameBridgeActive) {
        // Animação suave para mostrar as camadas, se não estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity < 1.0) {
            g_maskLayer.opacity = MIN(g_maskLayer.opacity + 0.1, 1.0);
        }
        if (g_previewLayer != nil) {
            if (g_previewLayer.opacity < 1.0) {
                g_previewLayer.opacity = MIN(g_previewLayer.opacity + 0.1, 1.0);
            }
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
    } else {
        // Animação suave para esconder as camadas, se estiverem visíveis
        if (g_maskLayer != nil && g_maskLayer.opacity > 0.0) {
            g_maskLayer.opacity = MAX(g_maskLayer.opacity - 0.1, 0.0);
        }
        if (g_previewLayer != nil && g_previewLayer.opacity > 0.0) {
            g_previewLayer.opacity = MAX(g_previewLayer.opacity - 0.1, 0.0);
        }
        return; // Evita processamento adicional se não estiver ativo
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
            writeLog(@"Atualizando tamanho das camadas: %@", NSStringFromCGRect(self.bounds));
        }
        
        // Aplica rotação apenas se a orientação mudou
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
            writeLog(@"Aplicou rotação para orientação: %d", (int)g_photoOrientation);
        }

        // Controle para evitar conflito com VideoDataOutput
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        
        // Atualiza o preview apenas se não houver atualização recente do VideoDataOutput
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            // Controle de taxa de frames (30 FPS)
            if (nowTime - refreshTime > 1000 / 30 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                
                // Obtém o próximo frame
                CMSampleBufferRef newBuffer = [[FrameBridge sharedInstance] getCurrentFrame:nil forceReNew:NO];
                if (newBuffer != nil) {
                    // Limpa quaisquer frames na fila
                    [g_previewLayer flush];
                    
                    // Cria uma cópia e adiciona à camada de preview
                    static CMSampleBufferRef copyBuffer = nil;
                    if (copyBuffer != nil) {
                        CFRelease(copyBuffer);
                        copyBuffer = nil;
                    }
                    
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer != nil) {
                        [g_previewLayer enqueueSampleBuffer:copyBuffer];
                        writeLog(@"Frame adicionado ao preview layer via displayLink");
                    }
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
    g_cameraRunning = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
    
    // Verificar explicitamente o estado do FrameBridge
    writeLog(@"AVCaptureSession::startRunning - FrameBridge.isActive = %d", isFrameBridgeActive());
    
    writeLog(@"AVCaptureSession iniciada com preset: %@", [self sessionPreset]);
    %orig;
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    writeLog(@"AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    %orig;
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    writeLog(@"AVCaptureSession::addInput - Adicionando dispositivo: %@", [input device]);
    
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
        writeLog(@"Posição da câmera definida como: %@", g_cameraPosition);
    }
    %orig;
}

// Método chamado quando um dispositivo de saída é adicionado à sessão
- (void)addOutput:(AVCaptureOutput *)output{
    writeLog(@"AVCaptureSession::addOutput - Adicionando output: %@", output);
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
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
        writeLog(@"Configurações de vídeo: %@", [self videoSettings]);
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Atualiza timestamp para controle de conflito com preview
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                
                // Armazena a orientação atual do vídeo
                g_photoOrientation = [connection videoOrientation];
                
                // Verificar explicitamente o estado do FrameBridge
                BOOL isActive = isFrameBridgeActive();
                writeLog(@"captureOutput: verificando FrameBridge.isActive = %d", isActive);
                
                // Verifica se o FrameBridge está ativo (recebendo frames do WebRTC)
                if (isActive) {
                    writeLog(@"AVCaptureOutput - Tentando substituir buffer com frame do WebRTC");
                    
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef newBuffer = [[FrameBridge sharedInstance] getCurrentFrame:sampleBuffer forceReNew:NO];
                    
                    // Atualiza o preview usando o buffer
                    if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        writeLog(@"Atualizando preview layer com frame WebRTC");
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                    }
                    
                    // Chama o método original com o buffer substituído se disponível
                    if (newBuffer != nil) {
                        writeLog(@"Usando buffer WebRTC para substituição");
                        return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer, connection);
                    }
                    
                    writeLog(@"Frame do WebRTC não disponível, usando buffer original");
                }
                
                // Se não há frame WebRTC para substituir, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Hook para os controles de volume
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        writeLog(@"Sequência volume-up + volume-down detectada, abrindo menu");

        // Verifica se o WebRTC está ativo
        BOOL isActive = isFrameBridgeActive();
        
        // Cria alerta para mostrar status e opções
        NSString *title = isActive ? @"WebRTC-VCAM ✅" : @"WebRTC-VCAM";
        NSString *message = isActive ?
            @"A substituição da câmera está ativa." :
            @"A substituição da câmera está desativada.";
        
        UIAlertController *alertController = [UIAlertController
            alertControllerWithTitle:title
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        
        // Opção para ativar/desativar substituição
        if (isActive) {
            UIAlertAction *disableAction = [UIAlertAction
                actionWithTitle:@"Desativar substituição"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    // Parar WebRTC
                    if (webRTCManager) {
                        [webRTCManager stopWebRTC:YES];
                    }
                    
                    // Desativar FrameBridge
                    if (frameBridge) {
                        [frameBridge releaseResources];
                    }
                    
                    // Mostrar confirmação
                    UIAlertController *confirmAlert = [UIAlertController
                        alertControllerWithTitle:@"Desativado"
                        message:@"A substituição da câmera foi desativada."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:confirmAlert animated:YES completion:nil];
                }];
            [alertController addAction:disableAction];
            
            // Opção para mostrar preview
            UIAlertAction *previewAction = [UIAlertAction
                actionWithTitle:@"Mostrar Preview"
                style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    // Mostrar janela de preview
                    [FloatingWindow showWithWebRTCManager:webRTCManager];
                }];
            [alertController addAction:previewAction];
        } else {
            // Opção para ativar
            UIAlertAction *enableAction = [UIAlertAction
                actionWithTitle:@"Ativar substituição"
                style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    // Iniciar WebRTC
                    if (webRTCManager) {
                        [webRTCManager startWebRTC];
                    }
                    
                    // Mostrar confirmação
                    UIAlertController *confirmAlert = [UIAlertController
                        alertControllerWithTitle:@"Ativado"
                        message:@"A substituição da câmera foi ativada."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:confirmAlert animated:YES completion:nil];
                }];
            [alertController addAction:enableAction];
        }
        
        // Opção para cancelar
        UIAlertAction *cancelAction = [UIAlertAction
            actionWithTitle:@"Fechar"
            style:UIAlertActionStyleCancel
            handler:nil];
        
        // Adiciona a ação ao alerta
        [alertController addAction:cancelAction];
        
        // Apresenta o alerta
        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alertController animated:YES completion:nil];
    }
    
    // Salva o timestamp atual
    g_volume_down_time = nowtime;
    
    // Chama o método original
    %orig;
}
%end

// Função chamada quando o tweak é carregado
%ctor {
    writeLog(@"--------------------------------------------------");
    writeLog(@"WebRTC-VCAM - Inicializando tweak");
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    
    // Inicializar hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        writeLog(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializar FloatingWindow e WebRTCManager com pequeno delay para o sistema terminar de inicializar
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando WebRTCManager e FrameBridge");
        
        // Inicializar FrameBridge (importante inicializar antes do WebRTCManager)
        frameBridge = [FrameBridge sharedInstance];
        
        // Inicializar WebRTCManager
        webRTCManager = [[WebRTCManager alloc] initWithDelegate:nil]; // Sem delegate na inicialização
        
        writeLog(@"WebRTC-VCAM componentes inicializados");
    });
    
    writeLog(@"WebRTC-VCAM inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor {
    writeLog(@"WebRTC-VCAM - Finalizando tweak");
    
    // Limpa recursos globais
    if (webRTCManager) {
        [webRTCManager stopWebRTC:YES];
    }
    webRTCManager = nil;
    
    if (frameBridge) {
        [frameBridge releaseResources];
    }
    frameBridge = nil;
    
    hookedClasses = nil;
    
    // Destruir a janela de preview se estiver visível
    [FloatingWindow destroy];
    
    writeLog(@"WebRTC-VCAM finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
