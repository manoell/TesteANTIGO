#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "DarwinNotifications.h"

// -------------- CONFIGURAÇÃO GLOBAL --------------
// Flag que controla a ativação/desativação do tweak (agora usando Darwin Notifications)
static BOOL g_tweakEnabled = YES;                          // Começa ativado por padrão

// Variáveis globais para gerenciamento de recursos
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static CALayer *g_maskLayer = nil;                         // Camada de máscara
static NSFileManager *g_fileManager = nil;                 // Objeto para gerenciamento de arquivos
static NSString *const g_videoFile = @"/var/mobile/Media/DCIM/default.mp4";  // Caminho do arquivo de vídeo
static NSString *g_cameraPosition = @"B";                  // Posição da câmera: "B" (traseira) ou "F" (frontal)
static BOOL g_cameraRunning = NO;                          // Status da sessão de câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // Timestamp da última atualização

// Variáveis para otimização de recursos de vídeo
static BOOL g_bufferReload = YES;                          // Controle de recarregamento de vídeo

// Variáveis para controle da interface
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Forward declaration para GetFrame
@protocol GetFrameProtocol <NSObject>
+ (instancetype)sharedInstance;
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer;
- (void)releaseResources;
@end

// -------------- FUNÇÕES UTILITÁRIAS --------------

// Função para sincronizar estado entre processos usando Darwin Notifications
static void syncTweakState(BOOL enabled) {
    // Define o estado local
    g_tweakEnabled = enabled;
    
    // Propaga estado para outros processos via Darwin Notifications
    registerBurladorActive(enabled);
    
    // Log da mudança de estado
    writeLog(@"[syncTweakState] Estado do tweak alterado para: %@", enabled ? @"ATIVADO" : @"DESATIVADO");
    
    // Atualiza imediatamente a visibilidade das camadas
    if (!enabled) {
        // 100% invisível quando desativado
        if (g_maskLayer) g_maskLayer.opacity = 0.0;
        if (g_previewLayer) g_previewLayer.opacity = 0.0;
        
        // Força reset ao desativar
        g_bufferReload = YES;
        Class getFrameClass = NSClassFromString(@"GetFrame");
        if (getFrameClass) {
            id instance = [getFrameClass performSelector:@selector(sharedInstance)];
            if ([instance respondsToSelector:@selector(releaseResources)]) {
                [instance performSelector:@selector(releaseResources)];
            }
        }
    } else {
        // 100% visível quando ativado
        if (g_maskLayer) g_maskLayer.opacity = 1.0;
        if (g_previewLayer) g_previewLayer.opacity = 1.0;
        
        // Força recarregamento do vídeo ao ativar
        g_bufferReload = YES;
    }
}

// Função para verificar o estado atual do tweak via Darwin Notifications
static void checkTweakState() {
    // Lê o estado das notificações Darwin
    BOOL stateFromNotification = isBurladorActive();
    
    // Se o estado local for diferente do estado nas notificações, sincroniza
    if (g_tweakEnabled != stateFromNotification) {
        writeLog(@"[checkTweakState] Sincronizando estado: %d -> %d", g_tweakEnabled, stateFromNotification);
        g_tweakEnabled = stateFromNotification;
        
        // Atualiza visibilidade das camadas
        if (g_maskLayer) g_maskLayer.opacity = g_tweakEnabled ? 1.0 : 0.0;
        if (g_previewLayer) g_previewLayer.opacity = g_tweakEnabled ? 1.0 : 0.0;
    }
}

// Função para mostrar o alerta de status/toggle
static void showMenuAlert(UIViewController *viewController) {
    // Verifica o estado atual antes de mostrar o menu
    checkTweakState();
    
    // Estado do tweak
    NSString *title = g_tweakEnabled ? @"iOS-VCAM ✅" : @"iOS-VCAM";
    NSString *message = g_tweakEnabled ? @"A substituição da câmera está ativa." : @"A substituição da câmera está desativada.";
    
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    
    // Botão para ativar/desativar
    NSString *toggleTitle = g_tweakEnabled ? @"Desativar" : @"Ativar";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_tweakEnabled ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            // Inverte o estado e sincroniza via Darwin Notifications
            syncTweakState(!g_tweakEnabled);
            
            // Notifica o usuário sobre a mudança de estado
            UIAlertController *confirmationAlert = [UIAlertController
                alertControllerWithTitle:@"iOS-VCAM"
                message:[NSString stringWithFormat:@"A substituição da câmera foi %@.",
                          g_tweakEnabled ? @"ATIVADA" : @"DESATIVADA"]
                preferredStyle:UIAlertControllerStyleAlert];
                
            [confirmationAlert addAction:[UIAlertAction
                actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault
                handler:nil]];
                
            [viewController presentViewController:confirmationAlert animated:YES completion:nil];
        }];
    
    // Botão para fechar
    UIAlertAction *closeAction = [UIAlertAction
        actionWithTitle:@"Fechar"
        style:UIAlertActionStyleCancel
        handler:nil];
    
    // Adiciona as ações ao alerta
    [alertController addAction:toggleAction];
    [alertController addAction:closeAction];
    
    // Apresenta o alerta
    [viewController presentViewController:alertController animated:YES completion:nil];
}

// Função para obter a janela principal
static UIWindow* getKeyWindow() {
    UIWindow *keyWindow = nil;
    NSArray *windows = UIApplication.sharedApplication.windows;
    
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    
    // Fallback para iOS 13+
    if (!keyWindow && windows.count > 0) {
        keyWindow = windows[0];
    }
    
    return keyWindow;
}

// -------------- CLASSE PARA GERENCIAMENTO DE FRAMES --------------

@interface GetFrame : NSObject <GetFrameProtocol>
@end

@implementation GetFrame {
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_videoTrackout_32BGRA;
    AVAssetReaderTrackOutput *_videoTrackout_420YpCbCr8BiPlanarVideoRange;
    AVAssetReaderTrackOutput *_videoTrackout_420YpCbCr8BiPlanarFullRange;
    CMSampleBufferRef _sampleBuffer;
    dispatch_queue_t _processingQueue;
    AVAsset *_videoAsset;
    BOOL _isSetup;
}

// Implementação Singleton
+ (instancetype)sharedInstance {
    static GetFrame *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _processingQueue = dispatch_queue_create("com.vcam.processing", DISPATCH_QUEUE_SERIAL);
        _reader = nil;
        _videoTrackout_32BGRA = nil;
        _videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
        _videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
        _sampleBuffer = nil;
        _videoAsset = nil;
        _isSetup = NO;
    }
    return self;
}

- (void)dealloc {
    [self releaseResources];
}

- (void)releaseResources {
    @synchronized (self) {
        writeLog(@"GetFrame::releaseResources - Liberando recursos do vídeo");
        
        if (_sampleBuffer != nil) {
            CFRelease(_sampleBuffer);
            _sampleBuffer = nil;
        }
        
        _reader = nil;
        _videoTrackout_32BGRA = nil;
        _videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
        _videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
        _videoAsset = nil;
        _isSetup = NO;
    }
}

// Método para configurar o leitor de vídeo
- (BOOL)setupVideoReader {
    @try {
        @synchronized (self) {
            // Verificação crítica - não configura se o tweak estiver desativado
            // Verifica o estado atual do tweak via Darwin Notifications
            checkTweakState();
            if (!g_tweakEnabled) {
                return NO;
            }
            
            // Verificamos se já está configurado
            if (_isSetup) {
                return YES;
            }
            
            // Verificamos se existe um arquivo de vídeo para substituição
            if (![g_fileManager fileExistsAtPath:g_videoFile]) {
                return NO;
            }
            
            // Criamos um AVAsset a partir do arquivo de vídeo
            NSURL *videoURL = [NSURL fileURLWithPath:g_videoFile];
            _videoAsset = [AVAsset assetWithURL:videoURL];
            
            if (!_videoAsset) {
                return NO;
            }
            
            NSError *error = nil;
            _reader = [AVAssetReader assetReaderWithAsset:_videoAsset error:&error];
            if (error) {
                return NO;
            }
            
            AVAssetTrack *videoTrack = [[_videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!videoTrack) {
                return NO;
            }
            
            // Configuramos outputs para diferentes formatos de pixel
            NSDictionary *outputSettings32BGRA = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
            _videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings32BGRA];
            
            NSDictionary *outputSettingsVideoRange = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
            _videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettingsVideoRange];
            
            NSDictionary *outputSettingsFullRange = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
            _videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettingsFullRange];
            
            [_reader addOutput:_videoTrackout_32BGRA];
            [_reader addOutput:_videoTrackout_420YpCbCr8BiPlanarVideoRange];
            [_reader addOutput:_videoTrackout_420YpCbCr8BiPlanarFullRange];
            
            if (![_reader startReading]) {
                return NO;
            }
            
            _isSetup = YES;
            return YES;
        }
    } @catch (NSException *exception) {
        return NO;
    }
}

// Verifica se o leitor de vídeo está no fim e reinicia se necessário
- (void)checkAndRestartReaderIfNeeded {
    // Verifica o estado atual do tweak via Darwin Notifications
    checkTweakState();
    
    // Não faz nada se o tweak estiver desativado
    if (!g_tweakEnabled) {
        return;
    }
    
    @synchronized (self) {
        if (_reader && _reader.status == AVAssetReaderStatusCompleted) {
            [self releaseResources];
            [self setupVideoReader];
        }
    }
}

// Método para obter o frame atual de vídeo
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer {
    // Verifica o estado atual do tweak via Darwin Notifications
    checkTweakState();
    
    // VERIFICAÇÃO CRÍTICA - se o tweak estiver desativado, retorna o buffer original
    if (!g_tweakEnabled) {
        return originSampleBuffer;
    }
    
    // Verificação de existência do arquivo
    if (![g_fileManager fileExistsAtPath:g_videoFile]) {
        return originSampleBuffer;
    }
    
    __block CMSampleBufferRef result = nil;
    
    dispatch_sync(_processingQueue, ^{
        // Inicializa variáveis para análise do buffer
        CMFormatDescriptionRef formatDescription = nil;
        CMMediaType mediaType = -1;
        FourCharCode subMediaType = -1;
        
        // Se temos um buffer de entrada, extraímos suas informações
        if (originSampleBuffer != nil) {
            formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
            if (formatDescription) {
                mediaType = CMFormatDescriptionGetMediaType(formatDescription);
                subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
                
                // Se não for vídeo, retornamos o buffer original sem alterações
                if (mediaType != kCMMediaType_Video) {
                    result = originSampleBuffer;
                    return;
                }
            }
        }
        
        // Se precisamos recarregar o vídeo, inicializamos os componentes de leitura
        if (g_bufferReload || !_isSetup) {
            g_bufferReload = NO;
            
            [self releaseResources];
            if (![self setupVideoReader]) {
                result = originSampleBuffer;
                return;
            }
        }
        
        // Verificar se o leitor chegou ao final e reiniciar se necessário
        [self checkAndRestartReaderIfNeeded];
        
        // Obtém um novo frame de cada formato
        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [_videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];
        
        CMSampleBufferRef newsampleBuffer = nil;
        
        // Escolhe o buffer adequado com base no formato do buffer original
        switch (subMediaType) {
            case kCVPixelFormatType_32BGRA:
                if (videoTrackout_32BGRA_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
                }
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer);
                }
                break;
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                }
                break;
            default:
                // Para formatos desconhecidos, usamos o formato 420YpCbCr8BiPlanarFullRange como padrão
                if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                }
        }
        
        // Libera os buffers temporários
        if (videoTrackout_32BGRA_Buffer) CFRelease(videoTrackout_32BGRA_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);
        
        // Se não conseguimos criar um novo buffer, marca para recarregar na próxima vez
        if (newsampleBuffer == nil) {
            g_bufferReload = YES;
            result = originSampleBuffer;
            return;
        }
        
        // Libera o buffer antigo se existir
        if (_sampleBuffer != nil) {
            CFRelease(_sampleBuffer);
            _sampleBuffer = nil;
        }
        
        // Se temos um buffer original, precisamos copiar propriedades dele
        if (originSampleBuffer != nil) {
            CMSampleBufferRef copyBuffer = nil;
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);
            
            if (pixelBuffer) {
                // Obtém informações de tempo do buffer original
                CMSampleTimingInfo sampleTime = {
                    .duration = CMSampleBufferGetDuration(originSampleBuffer),
                    .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                    .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
                };
                
                // Cria descrição de formato de vídeo para o novo buffer
                CMVideoFormatDescriptionRef videoInfo = nil;
                OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                
                if (status == noErr && videoInfo != nil) {
                    // Cria um novo buffer baseado no pixelBuffer mas com as informações de tempo do original
                    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &sampleTime, &copyBuffer);
                    
                    if (status == noErr && copyBuffer != nil) {
                        _sampleBuffer = copyBuffer;
                    }
                    
                    CFRelease(videoInfo);
                }
            }
            
            CFRelease(newsampleBuffer);
        } else {
            // Se não temos buffer original, usamos o novo diretamente
            _sampleBuffer = newsampleBuffer;
        }
        
        // Verifica se o buffer final é válido
        if (_sampleBuffer != nil && CMSampleBufferIsValid(_sampleBuffer)) {
            result = _sampleBuffer;
        } else {
            result = originSampleBuffer;
        }
    });
    
    return result;
}
@end

// -------------- HOOKS --------------

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    
    // Garante que todas as camadas tenham o tamanho correto após layouts
    if (g_previewLayer != nil) {
        g_previewLayer.frame = self.bounds;
        if (g_maskLayer != nil) {
            g_maskLayer.frame = self.bounds;
        }
    }
}

- (void)addSublayer:(CALayer *)layer {
    %orig;

    // Configura display link para atualização contínua, se não existir
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
    }

    // Adiciona camadas de preview se ainda não existem
    if (![[self sublayers] containsObject:g_previewLayer]) {
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0; // Começa invisível
        
        // Configura o tipo de gravidade de vídeo para garantir comportamento consistente
        [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
        g_previewLayer.opacity = 0; // Começa invisível
        
        // Configura o tamanho das camadas imediatamente usando o bounds da camada atual
        g_previewLayer.frame = self.bounds;
        g_maskLayer.frame = self.bounds;
        
        // Insere as camadas na hierarquia
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        
        // Configuração adicional para o comportamento correto
        g_previewLayer.actions = @{
            @"opacity": [NSNull null],  // Desativa animação de opacidade
            @"bounds": [NSNull null],   // Desativa animação de bounds
            @"position": [NSNull null]  // Desativa animação de posição
        };
        
        g_maskLayer.actions = @{
            @"opacity": [NSNull null],
            @"bounds": [NSNull null],
            @"position": [NSNull null]
        };
    }
}

// Método adicionado para atualização contínua do preview
%new
- (void)step:(CADisplayLink *)sender {
    // Verifica o estado atual do tweak via Darwin Notifications
    checkTweakState();
    
    // VERIFICAÇÃO CRÍTICA: Se o tweak está desativado, garante que as camadas estejam invisíveis
    if (!g_tweakEnabled) {
        if (g_maskLayer != nil) {
            g_maskLayer.opacity = 0.0;
        }
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 0.0;
        }
        return;
    }
    
    // Verifica se o vídeo existe
    BOOL shouldShowOverlay = [g_fileManager fileExistsAtPath:g_videoFile];
    
    // Controla a visibilidade das camadas - simples e direto
    if (shouldShowOverlay) {
        // Atualiza o tamanho das camadas antes de torná-las visíveis
        BOOL needsResize = !CGRectEqualToRect(g_previewLayer.frame, self.bounds);
        if (needsResize) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        }
        
        // Camadas 100% visíveis quando ativado
        if (g_maskLayer != nil) {
            g_maskLayer.opacity = 1.0;
        }
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 1.0;
            // Usa gravidade fixa para comportamento consistente
            [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
        }
    } else {
        // Camadas 100% invisíveis quando não há vídeo
        if (g_maskLayer != nil) {
            g_maskLayer.opacity = 0.0;
        }
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 0.0;
        }
        return; // Evita processamento adicional
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil && g_tweakEnabled) {
        // Controle para evitar conflito com VideoDataOutput e limitar FPS
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        
        // Atualiza o preview apenas se não houver atualização recente do VideoDataOutput
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 100 &&
            nowTime - refreshTime > 33.33 && // Aprox. 30 FPS
            g_previewLayer.readyForMoreMediaData) {
            
            refreshTime = nowTime;
            
            // Obtém o próximo frame
            CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:nil];
            if (newBuffer != nil) {
                // Limpa quaisquer frames na fila
                [g_previewLayer flush];
                
                // Adiciona à camada de preview
                [g_previewLayer enqueueSampleBuffer:newBuffer];
            }
        }
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
-(void) startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
    
    // Verifica o estado atual do tweak
    checkTweakState();
    
    %orig;
}

-(void) stopRunning {
    g_cameraRunning = NO;
    %orig;
}

- (void)addInput:(AVCaptureDeviceInput *)input {
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
    }
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
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
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                // Atualiza timestamp para controle de conflito com preview
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                
                // Verifica o estado atual do tweak via Darwin Notifications
                checkTweakState();
                
                // VERIFICAÇÃO CRÍTICA: Se o tweak está desativado, não faz nada
                if (!g_tweakEnabled) {
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                          output, sampleBuffer, connection);
                }
                
                // Verifica se o arquivo de vídeo existe
                if ([g_fileManager fileExistsAtPath:g_videoFile]) {
                    // Obtém um frame do vídeo para substituir o buffer
                    CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:sampleBuffer];
                    
                    // Verifica se obtivemos um buffer válido e diferente do original
                    if (newBuffer != nil && newBuffer != sampleBuffer) {
                        // Atualiza o preview usando o buffer
                        if (g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                            [g_previewLayer flush];
                            [g_previewLayer enqueueSampleBuffer:newBuffer];
                        }
                        
                        // Chama o método original com o buffer substituído
                        return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                              output, newBuffer, connection);
                    }
                }
                
                // Se não há vídeo para substituir ou falhou, usa o buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                      output, sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Hook para os controles de volume
%hook VolumeControl
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    g_volume_up_time = nowtime;
    %orig;
}

-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        // Se temos uma combinação de teclas, mostramos o menu
        UIWindow *keyWindow = getKeyWindow();
        if (keyWindow && keyWindow.rootViewController) {
            showMenuAlert(keyWindow.rootViewController);
        }
    }
    
    g_volume_down_time = nowtime;
    %orig;
}
%end

// Observer para notificações Darwin - detecta mudanças de outros processos
static int notificationToken = 0;
static void observeTweakState() {
    // Registra para receber notificações
    int status = notify_register_dispatch(
        NOTIFICATION_BURLADOR_ACTIVATION,
        &notificationToken,
        dispatch_get_main_queue(),
        ^(int token) {
            // Quando recebe uma notificação, sincroniza o estado
            uint64_t state = 0;
            notify_get_state(token, &state);
            BOOL newState = (state == 1);
            
            // Log para verificação
            writeLog(@"[Observer] Recebeu notificação - Estado: %@", newState ? @"ATIVADO" : @"DESATIVADO");
            
            // Atualiza estado local sem enviar nova notificação (para evitar loop)
            if (g_tweakEnabled != newState) {
                g_tweakEnabled = newState;
                
                // Atualiza visibilidade das camadas
                if (g_maskLayer) g_maskLayer.opacity = newState ? 1.0 : 0.0;
                if (g_previewLayer) g_previewLayer.opacity = newState ? 1.0 : 0.0;
                
                // Força recarregamento se necessário
                if (newState) {
                    g_bufferReload = YES;
                }
            }
        }
    );
    
    if (status != NOTIFY_STATUS_OK) {
        writeLog(@"[Observer] Falha ao registrar para notificações: %d", status);
    }
}

// Função chamada quando o tweak é carregado
%ctor {
    writeLog(@"--------------------------------------------------");
    writeLog(@"iOS-VCAM - Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializa recursos globais
    g_fileManager = [NSFileManager defaultManager];
    
    // Registra como observador de notificações Darwin para sincronizar estado entre processos
    observeTweakState();
    
    // Verifica o estado atual via Darwin Notifications
    checkTweakState();
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Tweak inicializado com sucesso com estado: %@", g_tweakEnabled ? @"ATIVADO" : @"DESATIVADO");
}

// Função chamada quando o tweak é descarregado
%dtor {
    writeLog(@"iOS-VCAM - Finalizando tweak");
    
    // Desregistra das notificações
    if (notificationToken != 0) {
        notify_cancel(notificationToken);
    }
    
    // Libera recursos antes de descarregar
    g_fileManager = nil;
    g_previewLayer = nil;
    g_maskLayer = nil;
    g_cameraRunning = NO;
    
    writeLog(@"Tweak finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
