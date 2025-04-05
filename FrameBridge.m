#import "FrameBridge.h"
#import "logger.h" // Use o sistema de log existente

@interface FrameBridge ()

// Frame atual e informações relacionadas
@property (nonatomic, assign) CMSampleBufferRef currentSampleBuffer;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@property (nonatomic, assign) CMTime lastPresentationTime;
@property (nonatomic, assign) BOOL needsNewFrame;

// Filas para processamento thread-safe
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) dispatch_semaphore_t bufferSemaphore;

// Callback para notificar quando um novo frame está disponível
@property (nonatomic, copy) void (^newFrameCallback)(void);

@end

@implementation FrameBridge

#pragma mark - Inicialização e Singleton

+ (instancetype)sharedInstance {
    static FrameBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _processingQueue = dispatch_queue_create("com.vcam.framebridge.processing", DISPATCH_QUEUE_SERIAL);
        _bufferSemaphore = dispatch_semaphore_create(1);
        _currentSampleBuffer = NULL;
        _lastPixelBuffer = NULL;
        _needsNewFrame = YES;
        _isActive = NO;
        _lastPresentationTime = kCMTimeZero;
        
        writeLog(@"[FrameBridge] Inicializada");
    }
    return self;
}

- (void)dealloc {
    [self releaseResources];
}

#pragma mark - Gerenciamento de Recursos

- (void)releaseResources {
    dispatch_sync(_processingQueue, ^{
        writeLog(@"[FrameBridge] Liberando recursos");
        
        dispatch_semaphore_wait(self.bufferSemaphore, DISPATCH_TIME_FOREVER);
        
        if (self.currentSampleBuffer != NULL) {
            CFRelease(self.currentSampleBuffer);
            self.currentSampleBuffer = NULL;
        }
        
        if (self.lastPixelBuffer != NULL) {
            CVPixelBufferRelease(self.lastPixelBuffer);
            self.lastPixelBuffer = NULL;
        }
        
        dispatch_semaphore_signal(self.bufferSemaphore);
        
        self.isActive = NO;
        self.needsNewFrame = YES;
    });
}

#pragma mark - Processamento de Frames

- (void)processVideoFrame:(RTCVideoFrame *)frame {
    if (!frame) {
        writeLog(@"[FrameBridge] Frame recebido é nulo");
        return;
    }
    
    // Verifica se o buffer é válido e do tipo correto
    if (!frame.buffer) {
        writeLog(@"[FrameBridge] Buffer do frame é nulo");
        return;
    }
    
    // Verifica se é um buffer de pixel
    if (![frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        writeLog(@"[FrameBridge] Tipo de buffer não suportado: %@", [frame.buffer class]);
        return;
    }
    
    self.isActive = YES;
    
    @try {
        // Execute o processamento em um bloco try-catch para evitar crashes
        dispatch_async(_processingQueue, ^{
            @try {
                writeLog(@"[FrameBridge] Processando novo frame WebRTC");
                
                // Obtenha o buffer de pixel do frame WebRTC
                RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
                if (!rtcPixelBuffer) {
                    writeLog(@"[FrameBridge] RTCPixelBuffer é nulo");
                    return;
                }
                
                CVPixelBufferRef pixelBuffer = rtcPixelBuffer.pixelBuffer;
                if (!pixelBuffer) {
                    writeLog(@"[FrameBridge] CVPixelBuffer é nulo");
                    return;
                }
                
                // Verifica se o lock pode ser adquirido
                CVReturn lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                if (lockResult != kCVReturnSuccess) {
                    writeLog(@"[FrameBridge] Falha ao obter lock no pixel buffer: %d", lockResult);
                    return;
                }
                
                // Crie um timestamp para o buffer
                CMTime presentationTime = CMTimeMake((int64_t)(CACurrentMediaTime() * 1000), 1000);
                self.lastPresentationTime = presentationTime;
                
                // Obtenha informações do pixel buffer
                size_t width = CVPixelBufferGetWidth(pixelBuffer);
                size_t height = CVPixelBufferGetHeight(pixelBuffer);
                OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
                
                writeLog(@"[FrameBridge] Frame recebido: %zu x %zu, formato: %d", width, height, (int)pixelFormat);
                
                // Criamos uma cópia do buffer de pixel para uso no sample buffer
                CVPixelBufferRef newPixelBuffer = NULL;
                NSDictionary *pixelBufferAttributes = @{
                    (NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
                    (NSString*)kCVPixelBufferWidthKey: @(width),
                    (NSString*)kCVPixelBufferHeightKey: @(height),
                    (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                
                CVReturn cvErr = CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    width,
                    height,
                    pixelFormat,
                    (__bridge CFDictionaryRef)pixelBufferAttributes,
                    &newPixelBuffer
                );
                
                if (cvErr != kCVReturnSuccess || newPixelBuffer == NULL) {
                    writeLog(@"[FrameBridge] Erro ao criar pixel buffer: %d", cvErr);
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                    return;
                }
                
                // Obtém o lock no novo buffer para escrever dados
                CVReturn lockNewResult = CVPixelBufferLockBaseAddress(newPixelBuffer, 0);
                if (lockNewResult != kCVReturnSuccess) {
                    writeLog(@"[FrameBridge] Falha ao obter lock no novo pixel buffer: %d", lockNewResult);
                    CVPixelBufferRelease(newPixelBuffer);
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                    return;
                }
                
                // Agora copiamos os dados com verificações de segurança
                BOOL copySuccess = NO;
                
                @try {
                    // Para NV12 (formato YUV mais comum no iOS)
                    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                        
                        // Verifica se temos 2 planos
                        if (CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 &&
                            CVPixelBufferGetPlaneCount(newPixelBuffer) >= 2) {
                            
                            // Copiar plano Y
                            size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
                            size_t destYStride = CVPixelBufferGetBytesPerRowOfPlane(newPixelBuffer, 0);
                            uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
                            uint8_t *destY = CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 0);
                            
                            if (srcY && destY) {
                                for (size_t i = 0; i < height; i++) {
                                    memcpy(destY + i * destYStride, srcY + i * srcYStride, MIN(width, srcYStride));
                                }
                                
                                // Copiar plano UV (CbCr)
                                size_t srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
                                size_t destUVStride = CVPixelBufferGetBytesPerRowOfPlane(newPixelBuffer, 1);
                                uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                                uint8_t *destUV = CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 1);
                                
                                if (srcUV && destUV) {
                                    size_t uvHeight = height / 2; // Plano UV tem metade da altura
                                    
                                    for (size_t i = 0; i < uvHeight; i++) {
                                        memcpy(destUV + i * destUVStride, srcUV + i * srcUVStride, MIN(width, srcUVStride));
                                    }
                                    
                                    copySuccess = YES;
                                }
                            }
                        }
                    }
                    // Para BGRA
                    else if (pixelFormat == kCVPixelFormatType_32BGRA) {
                        size_t srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
                        size_t destStride = CVPixelBufferGetBytesPerRow(newPixelBuffer);
                        uint8_t *src = CVPixelBufferGetBaseAddress(pixelBuffer);
                        uint8_t *dest = CVPixelBufferGetBaseAddress(newPixelBuffer);
                        
                        if (src && dest) {
                            for (size_t i = 0; i < height; i++) {
                                memcpy(dest + i * destStride, src + i * srcStride, MIN(width * 4, srcStride));
                            }
                            copySuccess = YES;
                        }
                    }
                } @catch (NSException *e) {
                    writeLog(@"[FrameBridge] Exceção ao copiar dados do pixel buffer: %@", e);
                    copySuccess = NO;
                }
                
                // Desbloqueia os buffers
                CVPixelBufferUnlockBaseAddress(newPixelBuffer, 0);
                CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
                
                if (!copySuccess) {
                    writeLog(@"[FrameBridge] Falha ao copiar dados do pixel buffer");
                    CVPixelBufferRelease(newPixelBuffer);
                    return;
                }
                
                // Agora crie uma descrição de formato de vídeo
                CMVideoFormatDescriptionRef videoInfo = NULL;
                cvErr = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newPixelBuffer, &videoInfo);
                
                if (cvErr != kCVReturnSuccess || videoInfo == NULL) {
                    writeLog(@"[FrameBridge] Erro ao criar descrição de formato: %d", cvErr);
                    CVPixelBufferRelease(newPixelBuffer);
                    return;
                }
                
                // Configuração de timing
                CMSampleTimingInfo timing;
                timing.duration = kCMTimeInvalid;
                timing.presentationTimeStamp = presentationTime;
                timing.decodeTimeStamp = presentationTime;
                
                // Crie o sample buffer
                CMSampleBufferRef sampleBuffer = NULL;
                cvErr = CMSampleBufferCreateForImageBuffer(
                    kCFAllocatorDefault,
                    newPixelBuffer,
                    true,
                    NULL,
                    NULL,
                    videoInfo,
                    &timing,
                    &sampleBuffer
                );
                
                CFRelease(videoInfo);
                
                if (cvErr != kCVReturnSuccess || sampleBuffer == NULL) {
                    writeLog(@"[FrameBridge] Erro ao criar sample buffer: %d", cvErr);
                    CVPixelBufferRelease(newPixelBuffer);
                    return;
                }
                
                // Atualize o buffer atual com segurança
                if (dispatch_semaphore_wait(self.bufferSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
                    writeLog(@"[FrameBridge] Timeout ao aguardar semáforo, liberando recursos");
                    CFRelease(sampleBuffer);
                    CVPixelBufferRelease(newPixelBuffer);
                    return;
                }
                
                // Gerencia os recursos anteriores
                if (self.currentSampleBuffer != NULL) {
                    CFRelease(self.currentSampleBuffer);
                    self.currentSampleBuffer = NULL;
                }
                
                if (self.lastPixelBuffer != NULL) {
                    CVPixelBufferRelease(self.lastPixelBuffer);
                    self.lastPixelBuffer = NULL;
                }
                
                // Armazena os novos recursos
                self.currentSampleBuffer = sampleBuffer;
                self.lastPixelBuffer = newPixelBuffer;
                self.needsNewFrame = NO;
                
                dispatch_semaphore_signal(self.bufferSemaphore);
                
                // Chame o callback se definido
                if (self.newFrameCallback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.newFrameCallback) {
                            self.newFrameCallback();
                        }
                    });
                }
                
                writeLog(@"[FrameBridge] Frame processado com sucesso");
            } @catch (NSException *e) {
                writeLog(@"[FrameBridge] Exceção não tratada: %@", e);
            }
        });
    } @catch (NSException *e) {
        writeLog(@"[FrameBridge] Exceção externa: %@", e);
    }
}

#pragma mark - Obtenção de Frames

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)srcBuffer forceReNew:(BOOL)forceReNew {
    __block CMSampleBufferRef result = NULL;
    
    dispatch_sync(_processingQueue, ^{
        writeLog(@"[FrameBridge] Solicitação de frame atual");
        
        // Se não estamos ativos ou não temos frame, retorne NULL
        if (!self.isActive || self.currentSampleBuffer == NULL) {
            writeLog(@"[FrameBridge] Nenhum frame disponível");
            result = NULL;
            return;
        }
        
        dispatch_semaphore_wait(self.bufferSemaphore, DISPATCH_TIME_FOREVER);
        
        // Se não precisamos criar um novo e não foi solicitado forçar renovação
        if (!self.needsNewFrame && !forceReNew) {
            writeLog(@"[FrameBridge] Retornando frame existente");
            // Cria uma cópia do buffer atual para evitar problemas de thread safety
            CMSampleBufferRef copiedBuffer = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, self.currentSampleBuffer, &copiedBuffer);
            result = copiedBuffer;
            dispatch_semaphore_signal(self.bufferSemaphore);
            return;
        }
        
        // Se temos um buffer de origem, precisamos adaptar nosso frame às suas propriedades
        if (srcBuffer != NULL) {
            writeLog(@"[FrameBridge] Adaptando frame ao formato do buffer original");
            
            // Extrair informações do buffer original
            CMFormatDescriptionRef srcFormat = CMSampleBufferGetFormatDescription(srcBuffer);
            CMMediaType mediaType = CMFormatDescriptionGetMediaType(srcFormat);
            FourCharCode subMediaType = CMFormatDescriptionGetMediaSubType(srcFormat);
            
            writeLog(@"[FrameBridge] Buffer original - MediaType: %d, SubMediaType: %d",
                     (int)mediaType, (int)subMediaType);
            
            // Se não for vídeo, retorne NULL
            if (mediaType != kCMMediaType_Video) {
                writeLog(@"[FrameBridge] Buffer original não é vídeo");
                result = NULL;
                dispatch_semaphore_signal(self.bufferSemaphore);
                return;
            }
            
            // Obtém informações de tempo do buffer original
            CMSampleTimingInfo sampleTime = {
                .duration = CMSampleBufferGetDuration(srcBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(srcBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(srcBuffer)
            };
            
            // Criar novo buffer adaptado
            CVPixelBufferRef pixelBuffer = self.lastPixelBuffer;
            
            if (pixelBuffer) {
                CMVideoFormatDescriptionRef videoInfo = NULL;
                OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
                    kCFAllocatorDefault,
                    pixelBuffer,
                    &videoInfo
                );
                
                if (status == noErr && videoInfo != NULL) {
                    CMSampleBufferRef adaptedBuffer = NULL;
                    status = CMSampleBufferCreateForImageBuffer(
                        kCFAllocatorDefault,
                        pixelBuffer,
                        true,
                        NULL,
                        NULL,
                        videoInfo,
                        &sampleTime,
                        &adaptedBuffer
                    );
                    
                    CFRelease(videoInfo);
                    
                    if (status == noErr && adaptedBuffer != NULL) {
                        result = adaptedBuffer;
                    } else {
                        writeLog(@"[FrameBridge] Erro ao criar buffer adaptado: %d", (int)status);
                        result = NULL;
                    }
                } else {
                    writeLog(@"[FrameBridge] Erro ao criar descrição de formato: %d", (int)status);
                    result = NULL;
                }
            } else {
                writeLog(@"[FrameBridge] Nenhum pixel buffer disponível");
                result = NULL;
            }
        } else {
            // Se não temos buffer de origem, simplesmente retorne uma cópia do atual
            writeLog(@"[FrameBridge] Retornando cópia do frame atual");
            CMSampleBufferRef copiedBuffer = NULL;
            CMSampleBufferCreateCopy(kCFAllocatorDefault, self.currentSampleBuffer, &copiedBuffer);
            result = copiedBuffer;
        }
        
        dispatch_semaphore_signal(self.bufferSemaphore);
    });
    
    return result;
}

#pragma mark - Callback

- (void)setNewFrameCallback:(void (^)(void))callback {
    // Usar a variável de instância diretamente para evitar o erro
    _newFrameCallback = [callback copy];
}

@end
