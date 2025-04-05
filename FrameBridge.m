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
    
    self.isActive = YES;
    
    @try {
        dispatch_async(_processingQueue, ^{
            @try {
                writeLog(@"[FrameBridge] Processando novo frame WebRTC");
                
                // Verificar o tipo de buffer e convertê-lo conforme necessário
                CVPixelBufferRef pixelBuffer = NULL;
                
                // Se for um buffer RTCCVPixelBuffer
                if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
                    RTCCVPixelBuffer *rtcPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
                    pixelBuffer = rtcPixelBuffer.pixelBuffer;
                }
                // Se for um buffer RTCI420Buffer (o caso que está falhando)
                else if ([frame.buffer isKindOfClass:[RTCI420Buffer class]]) {
                    RTCI420Buffer *i420Buffer = (RTCI420Buffer *)frame.buffer;
                    
                    // Obter dimensões e dados do buffer I420
                    int width = i420Buffer.width;
                    int height = i420Buffer.height;
                    const uint8_t *dataY = i420Buffer.dataY;
                    const uint8_t *dataU = i420Buffer.dataU;
                    const uint8_t *dataV = i420Buffer.dataV;
                    int strideY = i420Buffer.strideY;
                    int strideU = i420Buffer.strideU;
                    int strideV = i420Buffer.strideV;
                    
                    // Criar um CVPixelBuffer no formato NV12 (420YpCbCr8BiPlanarVideoRange)
                    NSDictionary *pixelAttributes = @{
                        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
                    };
                    
                    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                                        width, height,
                                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                        (__bridge CFDictionaryRef)pixelAttributes,
                                                        &pixelBuffer);
                    
                    if (result != kCVReturnSuccess) {
                        writeLog(@"[FrameBridge] Falha ao criar CVPixelBuffer");
                        return;
                    }
                    
                    // Bloquear buffer para escrita
                    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
                    
                    // Copiar plano Y
                    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
                    int dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
                    
                    for (int i = 0; i < height; i++) {
                        memcpy(dstY + i * dstStrideY, dataY + i * strideY, width);
                    }
                    
                    // Copiar e intercalar planos U e V para formato NV12 (UV intercalado)
                    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
                    int dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
                    
                    int chromaHeight = height / 2;
                    int chromaWidth = width / 2;
                    
                    for (int i = 0; i < chromaHeight; i++) {
                        uint8_t *dstRow = dstUV + i * dstStrideUV;
                        const uint8_t *srcRowU = dataU + i * strideU;
                        const uint8_t *srcRowV = dataV + i * strideV;
                        
                        for (int j = 0; j < chromaWidth; j++) {
                            dstRow[j * 2] = srcRowU[j];     // U
                            dstRow[j * 2 + 1] = srcRowV[j]; // V
                        }
                    }
                    
                    // Desbloquear buffer
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
                }
                else {
                    writeLog(@"[FrameBridge] Tipo de buffer não suportado: %@", [frame.buffer class]);
                    return;
                }
                
                if (pixelBuffer == NULL) {
                    writeLog(@"[FrameBridge] Falha ao obter/criar pixelBuffer");
                    return;
                }
                
                // O resto do seu código para criar CMSampleBuffer a partir do pixelBuffer...
                // (continuar usando seu código existente que processa o CVPixelBufferRef)
                
                // Timestamp para o buffer
                CMTime presentationTime = CMTimeMake((int64_t)(CACurrentMediaTime() * 1000), 1000);
                self.lastPresentationTime = presentationTime;
                
                // Criar descrição de formato de vídeo
                CMVideoFormatDescriptionRef videoInfo = NULL;
                OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
                
                if (status != kCVReturnSuccess || videoInfo == NULL) {
                    writeLog(@"[FrameBridge] Erro ao criar descrição de formato: %d", (int)status);
                    CVPixelBufferRelease(pixelBuffer);
                    return;
                }
                
                // Configuração de timing
                CMSampleTimingInfo timing;
                timing.duration = kCMTimeInvalid;
                timing.presentationTimeStamp = presentationTime;
                timing.decodeTimeStamp = presentationTime;
                
                // Crie o sample buffer
                CMSampleBufferRef sampleBuffer = NULL;
                status = CMSampleBufferCreateForImageBuffer(
                    kCFAllocatorDefault,
                    pixelBuffer,
                    true,
                    NULL,
                    NULL,
                    videoInfo,
                    &timing,
                    &sampleBuffer
                );
                
                CFRelease(videoInfo);
                
                if (status != kCVReturnSuccess || sampleBuffer == NULL) {
                    writeLog(@"[FrameBridge] Erro ao criar sample buffer: %d", (int)status);
                    CVPixelBufferRelease(pixelBuffer);
                    return;
                }
                
                // Atualizar buffer atual com semáforo
                if (dispatch_semaphore_wait(self.bufferSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
                    writeLog(@"[FrameBridge] Timeout ao aguardar semáforo, liberando recursos");
                    CFRelease(sampleBuffer);
                    CVPixelBufferRelease(pixelBuffer);
                    return;
                }
                
                // Gerenciar recursos anteriores
                if (self.currentSampleBuffer != NULL) {
                    CFRelease(self.currentSampleBuffer);
                    self.currentSampleBuffer = NULL;
                }
                
                if (self.lastPixelBuffer != NULL) {
                    CVPixelBufferRelease(self.lastPixelBuffer);
                    self.lastPixelBuffer = NULL;
                }
                
                // Armazenar novos recursos
                self.currentSampleBuffer = sampleBuffer;
                self.lastPixelBuffer = pixelBuffer;
                self.needsNewFrame = NO;
                
                dispatch_semaphore_signal(self.bufferSemaphore);
                
                // Chamar callback se existir
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
