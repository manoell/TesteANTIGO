#import "WebRTCManager.h"
#import <UIKit/UIKit.h>
#import "logger.h"

// Variáveis globais para gerenciamento do tweak
static WebRTCManager *webRTCManager = nil;
static BOOL g_cameraRunning = NO;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0;
static NSString *g_cameraPosition = @"B";  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait;

// Elementos de UI para o tweak
static CALayer *g_maskLayer = nil;

// Variáveis para controle da interface de usuário
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
    // Verifica se o WebRTCManager está recebendo frames e a substituição está ativa
    BOOL shouldShowSubstitution = webRTCManager && webRTCManager.isReceivingFrames && webRTCManager.isSubstitutionActive;
    
    // Controla a visibilidade das camadas baseado na ativação da substituição
    if (shouldShowSubstitution) {
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
        return; // Evita processamento adicional se não houver substituição ativa
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil) {
        // Atualiza o tamanho da camada de preview
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
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
        }

        // Controle para evitar conflito com VideoDataOutput
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        
        // Atualiza o preview apenas se não houver atualização recente do VideoDataOutput
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            // Controle de taxa de frames (30 FPS)
            if (nowTime - refreshTime > 1000 / 30 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                
                // Obtém o próximo frame usando o WebRTCManager
                // Passa NULL como originSampleBuffer pois não temos um aqui
                CMSampleBufferRef newBuffer = [webRTCManager getCurrentFrame:nil forceReNew:NO];
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
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
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
                
                // Verifica se o WebRTCManager está recebendo frames e a substituição está ativa
                if (webRTCManager && webRTCManager.isReceivingFrames && webRTCManager.isSubstitutionActive) {
                    // Obtém um frame do WebRTC para substituir o buffer
                    CMSampleBufferRef newBuffer = [webRTCManager getCurrentFrame:sampleBuffer forceReNew:NO];
                    
                    // Atualiza o preview usando o buffer substituído
                    if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                        [g_previewLayer flush];
                        [g_previewLayer enqueueSampleBuffer:newBuffer];
                    }
                    
                    // Chama o método original com o buffer substituído ou o original se não houver frame disponível
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer != nil ? newBuffer : sampleBuffer, connection);
                }
                
                // Se a substituição não está ativa, usa o buffer original
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
        BOOL webrtcActive = webRTCManager && webRTCManager.isReceivingFrames;
        BOOL substitutionActive = webRTCManager && webRTCManager.isSubstitutionActive;
        
        // Cria alerta para mostrar status e opções
        NSString *title = substitutionActive ? @"WebRTC-CAM ✅" : @"WebRTC-CAM";
        NSString *message = substitutionActive ?
            @"A substituição do feed da câmera está ativa." :
            (webrtcActive ? @"WebRTC está conectado mas substituição está inativa." : @"WebRTC não está conectado.");
        
        UIAlertController *alertController = [UIAlertController
            alertControllerWithTitle:title
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        
        // Opção para ativar/desativar substituição
        NSString *actionTitle = substitutionActive ?
            @"Desativar" : @"Ativar";
        
        UIAlertActionStyle actionStyle = substitutionActive ?
            UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
        
        UIAlertAction *toggleAction = [UIAlertAction
            actionWithTitle:actionTitle
            style:actionStyle
            handler:^(UIAlertAction *action) {
                writeLog(@"Opção '%@' escolhida", actionTitle);
                
                if (!webrtcActive && !substitutionActive) {
                    // Se WebRTC não está conectado, iniciar conexão
                    [webRTCManager startWebRTC];
                    
                    // Ativar substituição após pequeno delay para dar tempo de conectar
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (webRTCManager.isReceivingFrames) {
                            [webRTCManager setSubstitutionActive:YES];
                            writeLog(@"WebRTC conectado e substituição ativada");
                        }
                    });
                }
                else if (webrtcActive) {
                    if (substitutionActive) {
                        // Desativar substituição mas manter conexão
                        [webRTCManager setSubstitutionActive:NO];
                        writeLog(@"Substituição desativada, WebRTC ainda conectado");
                    } else {
                        // Ativar substituição
                        [webRTCManager setSubstitutionActive:YES];
                        writeLog(@"Substituição ativada");
                    }
                }
            }];
        [alertController addAction:toggleAction];
        
        // Opção para desconectar WebRTC (só aparece se estiver conectado)
        if (webrtcActive) {
            UIAlertAction *disconnectAction = [UIAlertAction
                actionWithTitle:@"Desconectar WebRTC"
                style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    writeLog(@"Opção 'Desconectar WebRTC' escolhida");
                    
                    // Desativa substituição primeiro para evitar problemas
                    [webRTCManager setSubstitutionActive:NO];
                    
                    // Para a conexão WebRTC
                    [webRTCManager stopWebRTC:YES];
                    
                    writeLog(@"WebRTC desconectado e substituição desativada");
                }];
            [alertController addAction:disconnectAction];
        }
        
        // Opção para cancelar
        UIAlertAction *cancelAction = [UIAlertAction
            actionWithTitle:@"Fechar"
            style:UIAlertActionStyleCancel
            handler:nil];
        
        // Adiciona as ações ao alerta
        [alertController addAction:cancelAction];
        
        // Apresenta o alerta
        UIWindow *keyWindow = nil;
        for(UIWindow *window in UIApplication.sharedApplication.windows) {
            if(window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        
        if (keyWindow) {
            [keyWindow.rootViewController presentViewController:alertController animated:YES completion:nil];
        }
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
    writeLog(@"WebRTC-CAM Tweak - Inicializando");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        writeLog(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializa o WebRTCManager sem nenhuma interface de usuário
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando WebRTCManager");
        
        // Criar o WebRTCManager
        webRTCManager = [[WebRTCManager alloc] initWithDelegate:nil];
        
        // Por padrão, apenas inicializa mas não conecta e não ativa substituição
        writeLog(@"WebRTCManager inicializado, pronto para conectar via controles de volume");
    });
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    writeLog(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor{
    writeLog(@"WebRTC-CAM Tweak - Finalizando");
    
    // Desativa a substituição da câmera
    if (webRTCManager) {
        [webRTCManager setSubstitutionActive:NO];
    }
    
    // Para a conexão WebRTC
    if (webRTCManager) {
        [webRTCManager stopWebRTC:YES];
    }
    
    // Limpa variáveis globais
    webRTCManager = nil;
    g_cameraRunning = NO;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    
    writeLog(@"Tweak finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
