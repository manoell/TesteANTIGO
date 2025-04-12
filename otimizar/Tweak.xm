#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "logger.h"
#import "DarwinNotifications.h"

// -------------- CONFIGURAÇÃO GLOBAL --------------
static BOOL g_tweakEnabled = YES;                          // Estado do tweak
static AVSampleBufferDisplayLayer *g_previewLayer = nil;   // Layer para visualização da câmera
static CALayer *g_maskLayer = nil;                         // Camada de máscara
static NSFileManager *g_fileManager = nil;                 // Gerenciamento de arquivos
static NSString *const g_videoFile = @"/var/mobile/Media/DCIM/default.mp4";
static NSString *g_cameraPosition = @"B";                  // "B" (traseira) ou "F" (frontal)
static BOOL g_cameraRunning = NO;                          // Status da sessão de câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0;
static BOOL g_bufferReload = YES;                          // Controle de recarregamento de vídeo
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;
static int g_notificationObserverToken = 0;                // Token para observer de notificações

// Forward declaration para GetFrame
@protocol GetFrameProtocol <NSObject>
+ (instancetype)sharedInstance;
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer;
- (void)releaseResources;
@end

// -------------- FUNÇÕES UTILITÁRIAS --------------

// Função para sincronizar estado entre processos usando Darwin Notifications
static void syncTweakState(BOOL enabled) {
    g_tweakEnabled = enabled;
    registerBurladorActive(enabled);
    writeLog(@"[syncTweakState] Estado do tweak alterado para: %@", enabled ? @"ATIVADO" : @"DESATIVADO");
    
    // Atualiza imediatamente a visibilidade das camadas
    if (!enabled) {
        if (g_maskLayer) g_maskLayer.opacity = 0.0;
        if (g_previewLayer) g_previewLayer.opacity = 0.0;
        g_bufferReload = YES;
        
        // Reset quando desativado
        Class getFrameClass = NSClassFromString(@"GetFrame");
        if (getFrameClass) {
            id instance = [getFrameClass performSelector:@selector(sharedInstance)];
            if ([instance respondsToSelector:@selector(releaseResources)]) {
                [instance performSelector:@selector(releaseResources)];
            }
        }
    } else {
        if (g_maskLayer) g_maskLayer.opacity = 1.0;
        if (g_previewLayer) g_previewLayer.opacity = 1.0;
        g_bufferReload = YES;
    }
}

// Verifica o estado atual do tweak via Darwin Notifications
static void checkTweakState() {
    BOOL stateFromNotification = isBurladorActive();
    if (g_tweakEnabled != stateFromNotification) {
        writeLog(@"[checkTweakState] Sincronizando estado: %d -> %d", g_tweakEnabled, stateFromNotification);
        g_tweakEnabled = stateFromNotification;
        
        // Atualiza visibilidade das camadas
        if (g_maskLayer) g_maskLayer.opacity = g_tweakEnabled ? 1.0 : 0.0;
        if (g_previewLayer) g_previewLayer.opacity = g_tweakEnabled ? 1.0 : 0.0;
    }
}

// Mostra o alerta de status/toggle
static void showMenuAlert(UIViewController *viewController) {
    checkTweakState();
    
    NSString *title = g_tweakEnabled ? @"iOS-VCAM ✅" : @"iOS-VCAM";
    NSString *message = g_tweakEnabled ? @"A substituição da câmera está ativa." : @"A substituição da câmera está desativada.";
    
    UIAlertController *alertController = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    
    NSString *toggleTitle = g_tweakEnabled ? @"Desativar" : @"Ativar";
    UIAlertAction *toggleAction = [UIAlertAction
        actionWithTitle:toggleTitle
        style:g_tweakEnabled ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            syncTweakState(!g_tweakEnabled);
            
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
    
    [alertController addAction:toggleAction];
    [alertController addAction:[UIAlertAction
        actionWithTitle:@"Fechar"
        style:UIAlertActionStyleCancel
        handler:nil]];
    
    [viewController presentViewController:alertController animated:YES completion:nil];
}

// Obtém a janela principal
static UIWindow* getKeyWindow() {
    NSArray *windows = UIApplication.sharedApplication.windows;
    
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    
    // Fallback para iOS 13+
    return windows.count > 0 ? windows[0] : nil;
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

- (BOOL)setupVideoReader {
    @try {
        @synchronized (self) {
            checkTweakState();
            if (!g_tweakEnabled || _isSetup || ![g_fileManager fileExistsAtPath:g_videoFile]) {
                return _isSetup;
            }
            
            // Criar asset de vídeo
            NSURL *videoURL = [NSURL fileURLWithPath:g_videoFile];
            _videoAsset = [AVAsset assetWithURL:videoURL];
            
            if (!_videoAsset) {
                return NO;
            }
            
            // Configurar reader
            NSError *error = nil;
            _reader = [AVAssetReader assetReaderWithAsset:_videoAsset error:&error];
            if (error) {
                return NO;
            }
            
            // Obter track de vídeo
            AVAssetTrack *videoTrack = [[_videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (!videoTrack) {
                return NO;
            }
            
            // Configurar outputs para diferentes formatos de pixel
            _videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:videoTrack
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
            
            _videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:videoTrack
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            
            _videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:videoTrack
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
            
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

// Verifica e reinicia o reader se necessário
- (void)checkAndRestartReaderIfNeeded {
    checkTweakState();
    
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

// Obtém frame atual de vídeo
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer {
    checkTweakState();
    
    // Se desativado ou arquivo inexistente, retorna buffer original
    if (!g_tweakEnabled || ![g_fileManager fileExistsAtPath:g_videoFile]) {
        return originSampleBuffer;
    }
    
    __block CMSampleBufferRef result = nil;
    
    dispatch_sync(_processingQueue, ^{
        // Análise do buffer original
        CMFormatDescriptionRef formatDescription = nil;
        CMMediaType mediaType = -1;
        FourCharCode subMediaType = -1;
        
        if (originSampleBuffer != nil) {
            formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
            if (formatDescription) {
                mediaType = CMFormatDescriptionGetMediaType(formatDescription);
                subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
                
                // Se não for vídeo, retorna sem alterações
                if (mediaType != kCMMediaType_Video) {
                    result = originSampleBuffer;
                    return;
                }
            }
        }
        
        // Configura leitor de vídeo se necessário
        if (g_bufferReload || !_isSetup) {
            g_bufferReload = NO;
            
            [self releaseResources];
            if (![self setupVideoReader]) {
                result = originSampleBuffer;
                return;
            }
        }
        
        // Verifica fim do vídeo e reinicia se necessário
        [self checkAndRestartReaderIfNeeded];
        
        // Obtém frames nos diferentes formatos
        CMSampleBufferRef videoTrackout_32BGRA_Buffer = [_videoTrackout_32BGRA copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
        CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [_videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];
        
        CMSampleBufferRef newsampleBuffer = nil;
        
        // Seleciona o buffer baseado no formato do original
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
                // Fallback para formato padrão
                if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) {
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
                }
        }
        
        // Libera buffers temporários
        if (videoTrackout_32BGRA_Buffer) CFRelease(videoTrackout_32BGRA_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
        if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);
        
        // Se não conseguiu criar buffer, marca para recarregar e retorna original
        if (newsampleBuffer == nil) {
            g_bufferReload = YES;
            result = originSampleBuffer;
            return;
        }
        
        // Libera buffer antigo
        if (_sampleBuffer != nil) {
            CFRelease(_sampleBuffer);
            _sampleBuffer = nil;
        }
        
        // Transfere propriedades do buffer original para o novo
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
                
                // Cria descrição de formato de vídeo
                CMVideoFormatDescriptionRef videoInfo = nil;
                OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                
                if (status == noErr && videoInfo != nil) {
                    // Cria buffer final com timing do original
                    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &sampleTime, &copyBuffer);
                    
                    if (status == noErr && copyBuffer != nil) {
                        _sampleBuffer = copyBuffer;
                    }
                    
                    CFRelease(videoInfo);
                }
            }
            
            CFRelease(newsampleBuffer);
        } else {
            // Sem buffer original, usa o novo diretamente
            _sampleBuffer = newsampleBuffer;
        }
        
        // Verifica validade do buffer final
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
    
    // Atualiza tamanho das camadas após layout
    if (g_previewLayer != nil) {
        g_previewLayer.frame = self.bounds;
        if (g_maskLayer != nil) {
            g_maskLayer.frame = self.bounds;
        }
    }
}

- (void)addSublayer:(CALayer *)layer {
    %orig;

    // Configura display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        
        // Ajusta taxa de frames
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 30;
        } else {
            displayLink.frameInterval = 2;
        }
        
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }

    // Inicializa camadas de preview se necessário
    if (![[self sublayers] containsObject:g_previewLayer]) {
        // Inicializa camada de exibição
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Inicializa máscara
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        g_maskLayer.opacity = 0;
        
        // Configura propriedades da camada de exibição
        [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
        g_previewLayer.opacity = 0;
        
        // Define tamanho
        g_previewLayer.frame = self.bounds;
        g_maskLayer.frame = self.bounds;
        
        // Adiciona na hierarquia
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        
        // Desativa animações
        g_previewLayer.actions = @{
            @"opacity": [NSNull null],
            @"bounds": [NSNull null],
            @"position": [NSNull null]
        };
        
        g_maskLayer.actions = @{
            @"opacity": [NSNull null],
            @"bounds": [NSNull null],
            @"position": [NSNull null]
        };
    }
}

// Método para atualização contínua do preview
%new
- (void)step:(CADisplayLink *)sender {
    // Verifica estado atual
    checkTweakState();
    
    // Se desativado, garante camadas invisíveis
    if (!g_tweakEnabled) {
        if (g_maskLayer) g_maskLayer.opacity = 0.0;
        if (g_previewLayer) g_previewLayer.opacity = 0.0;
        return;
    }
    
    // Verifica existência do vídeo
    BOOL shouldShowOverlay = [g_fileManager fileExistsAtPath:g_videoFile];
    
    if (shouldShowOverlay) {
        // Atualiza tamanho se necessário
        if (!CGRectEqualToRect(g_previewLayer.frame, self.bounds)) {
            g_previewLayer.frame = self.bounds;
            g_maskLayer.frame = self.bounds;
        }
        
        // Torna camadas visíveis
        if (g_maskLayer) g_maskLayer.opacity = 1.0;
        if (g_previewLayer) {
            g_previewLayer.opacity = 1.0;
            [g_previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
        }
    } else {
        // Torna camadas invisíveis se não há vídeo
        if (g_maskLayer) g_maskLayer.opacity = 0.0;
        if (g_previewLayer) g_previewLayer.opacity = 0.0;
        return;
    }

    // Atualiza preview com frames do vídeo
    if (g_cameraRunning && g_previewLayer && g_tweakEnabled) {
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        
        // Controle de taxa de atualização
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 100 &&
            nowTime - refreshTime > 33.33 && // ~30 FPS
            g_previewLayer.readyForMoreMediaData) {
            
            refreshTime = nowTime;
            
            // Obtém próximo frame e o exibe
            CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:nil];
            if (newBuffer != nil) {
                [g_previewLayer flush];
                [g_previewLayer enqueueSampleBuffer:newBuffer];
            }
        }
    }
}
%end

// Hook para gerenciar estado da sessão da câmera
%hook AVCaptureSession
-(void) startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
    checkTweakState();
    %orig;
}

-(void) stopRunning {
    g_cameraRunning = NO;
    %orig;
}

- (void)addInput:(AVCaptureDeviceInput *)input {
    // Determina posição da câmera
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
    }
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    // Verificações de segurança
    if (!sampleBufferDelegate || !sampleBufferCallbackQueue) {
        return %orig;
    }
    
    // Lista para controlar classes já hooked
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Se ainda não foi hooked, faz o hook
    if (![hooked containsObject:className]) {
        [hooked addObject:className];
        
        __block void (*original_method)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) = nil;
        
        // Hook do método de captureOutput
        MSHookMessageEx(
            [sampleBufferDelegate class],
            @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                // Atualiza timestamp
                g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
                
                // Verifica estado
                checkTweakState();
                
                // Se desativado, passa buffer original
                if (!g_tweakEnabled) {
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                          output, sampleBuffer, connection);
                }
                
                // Verifica existência do vídeo
                if ([g_fileManager fileExistsAtPath:g_videoFile]) {
                    // Obtém frame de substituição
                    CMSampleBufferRef newBuffer = [[GetFrame sharedInstance] getCurrentFrame:sampleBuffer];
                    
                    // Se obteve buffer válido, usa-o
                    if (newBuffer && newBuffer != sampleBuffer) {
                        // Atualiza preview
                        if (g_previewLayer && g_previewLayer.readyForMoreMediaData) {
                            [g_previewLayer flush];
                            [g_previewLayer enqueueSampleBuffer:newBuffer];
                        }
                        
                        return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                              output, newBuffer, connection);
                    }
                }
                
                // Fallback para buffer original
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                                      output, sampleBuffer, connection);
            }),
            (IMP*)&original_method
        );
    }
    
    %orig;
}
%end

// Hook para controles de volume
%hook VolumeControl
-(void)increaseVolume {
    // Atualiza o timestamp de volume up
    g_volume_up_time = [[NSDate date] timeIntervalSince1970];
    
    // Reseta o controle após um período (5 segundos)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Só reseta se não tiver sido acionado o menu
        if (fabs([[NSDate date] timeIntervalSince1970] - g_volume_down_time) > 4.0) {
            g_volume_up_time = 0;
        }
    });
    
    %orig;
}

-(void)decreaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Detector de combinação de teclas - verifica por um período menor (0.8s)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 0.8) {
        UIWindow *keyWindow = getKeyWindow();
        if (keyWindow && keyWindow.rootViewController) {
            showMenuAlert(keyWindow.rootViewController);
            
            // Reseta imediatamente após mostrar o menu para evitar acionamentos acidentais
            g_volume_up_time = 0;
            g_volume_down_time = 0;
            
            // Não executa o comportamento original para evitar alterar o volume ao mostrar o menu
            return;
        }
    }
    
    g_volume_down_time = nowtime;
    %orig;
}
%end

// Observer para notificações Darwin
static void observeTweakState() {
    int status = notify_register_dispatch(
        NOTIFICATION_BURLADOR_ACTIVATION,
        &g_notificationObserverToken,
        dispatch_get_main_queue(),
        ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            BOOL newState = (state == 1);
            
            writeLog(@"[Observer] Recebeu notificação - Estado: %@", newState ? @"ATIVADO" : @"DESATIVADO");
            
            // Atualiza estado local sem enviar nova notificação
            if (g_tweakEnabled != newState) {
                g_tweakEnabled = newState;
                
                // Atualiza visibilidade
                if (g_maskLayer) g_maskLayer.opacity = newState ? 1.0 : 0.0;
                if (g_previewLayer) g_previewLayer.opacity = newState ? 1.0 : 0.0;
                
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

// Inicialização do tweak
%ctor {
    writeLog(@"--------------------------------------------------");
    writeLog(@"iOS-VCAM - Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializa recursos
    g_fileManager = [NSFileManager defaultManager];
    
    // Registra como observador de notificações
    observeTweakState();
    
    // Verifica estado atual
    checkTweakState();
    
    writeLog(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    writeLog(@"Tweak inicializado com sucesso com estado: %@", g_tweakEnabled ? @"ATIVADO" : @"DESATIVADO");
}

// Finalização do tweak
%dtor {
    writeLog(@"iOS-VCAM - Finalizando tweak");
    
    // Desregistra das notificações
    if (g_notificationObserverToken != 0) {
        notify_cancel(g_notificationObserverToken);
    }
    
    // Libera recursos
    g_fileManager = nil;
    g_previewLayer = nil;
    g_maskLayer = nil;
    g_cameraRunning = NO;
    
    writeLog(@"Tweak finalizado com sucesso");
    writeLog(@"--------------------------------------------------");
}
