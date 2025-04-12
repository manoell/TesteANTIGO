#import "WebRTCManager.h"
#import "logger.h"
#import "DarwinNotifications.h"

// Classe para captura eficiente de frames do VideoTrack
@interface RTCFrameCaptor : NSObject <RTCVideoRenderer>
@property (nonatomic, strong) RTCVideoFrame *lastFrame;
@property (nonatomic, strong) RTCCVPixelBuffer *lastCVPixelBuffer;
@property (nonatomic, strong) id<RTCI420Buffer> lastI420Buffer;
@property (nonatomic, assign) BOOL hasNewFrame;
@property (nonatomic, assign) CFTimeInterval lastCaptureTime;
@end

@implementation RTCFrameCaptor

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastFrame = nil;
        _lastCVPixelBuffer = nil;
        _lastI420Buffer = nil;
        _hasNewFrame = NO;
    }
    return self;
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    @synchronized (self) {
        _lastFrame = frame;
        _lastI420Buffer = nil;
        _lastCVPixelBuffer = nil;
        
        // Otimização: armazenar buffer já convertido
        if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            _lastCVPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
        } else {
            _lastI420Buffer = [frame.buffer toI420];
        }
        
        _lastCaptureTime = CACurrentMediaTime();
        _hasNewFrame = YES;
    }
}

- (void)setSize:(CGSize)size {
    // Requisito do protocolo RTCVideoRenderer
}

@end

@interface WebRTCManager () <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign, readwrite) BOOL isSubstitutionActive;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong, readwrite) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCFrameCaptor *frameCaptor;
@property (nonatomic, assign) BOOL hasJoinedRoom;
@property (nonatomic, assign) BOOL byeMessageSent;
@property (nonatomic, assign, readwrite) BOOL userRequestedDisconnect;

// Propriedades para processamento de frames
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) CMFormatDescriptionRef formatDescription;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) NSCache *frameCache;
@end

@implementation WebRTCManager

#pragma mark - Inicialização e Destruição

- (instancetype)initWithDelegate:(id<WebRTCManagerDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178";
        _hasJoinedRoom = NO;
        _byeMessageSent = NO;
        _isSubstitutionActive = NO;
        
        // Inicializar recursos para processamento de vídeo
        _frameCaptor = [[RTCFrameCaptor alloc] init];
        _videoQueue = dispatch_queue_create("com.webrtc.videoProcessing", DISPATCH_QUEUE_SERIAL);
        _frameCache = [[NSCache alloc] init];
        [_frameCache setCountLimit:5]; // Cache de 5 frames para suavizar reprodução
        
        writeLog(@"[WebRTCManager] Inicializado");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC:YES];
    
    if (_pixelBufferPool) {
        CVPixelBufferPoolRelease(_pixelBufferPool);
        _pixelBufferPool = NULL;
    }
    
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

#pragma mark - Gerenciamento de Estado

- (void)setState:(WebRTCManagerState)state {
    if (_state == state) return;
    
    WebRTCManagerState oldState = _state;
    _state = state;
    
    writeLog(@"[WebRTCManager] Estado alterado: %d → %d", (int)oldState, (int)state);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate didChangeConnectionState:state];
        [self.delegate didUpdateConnectionStatus:[self statusMessageForState:state]];
    });
    
    if (state == WebRTCManagerStateDisconnected) {
        self.hasJoinedRoom = NO;
        self.byeMessageSent = NO;
    }
}

- (NSString *)statusMessageForState:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected:
            return @"Desconectado";
        case WebRTCManagerStateConnecting:
            return @"Conectando ao servidor...";
        case WebRTCManagerStateConnected:
            return self.isReceivingFrames ? @"Conectado - Recebendo stream" : @"Conectado - Aguardando stream";
        case WebRTCManagerStateError:
            return @"Erro de conexão";
        case WebRTCManagerStateReconnecting:
            return @"Reconectando...";
        default:
            return @"Estado desconhecido";
    }
}

#pragma mark - Conexão WebRTC

- (void)startWebRTC {
    if (_state == WebRTCManagerStateConnected || _state == WebRTCManagerStateConnecting) {
        return;
    }
    
    // Definir IP padrão se necessário
    if (!self.serverIP.length) {
        self.serverIP = @"192.168.0.178";
    }
    
    self.userRequestedDisconnect = NO;
    self.hasJoinedRoom = NO;
    self.byeMessageSent = NO;
    
    writeLog(@"[WebRTCManager] Iniciando WebRTC");
    self.state = WebRTCManagerStateConnecting;
    
    // Garantir limpeza antes de iniciar
    [self performStopWebRTC];
    
    @try {
        [self configureWebRTCWithDefaults];
        [self connectWebSocket];
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Erro ao iniciar WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
        
        if (self.hasJoinedRoom && !self.byeMessageSent &&
            self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [self sendByeMessage];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self performStopWebRTC];
            });
        } else {
            [self performStopWebRTC];
        }
    } else {
        [self performStopWebRTC];
    }
}

- (void)performStopWebRTC {
    self.isReceivingFrames = NO;
    
    // Limpar VideoTrack
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self.frameCaptor];
        self.videoTrack = nil;
    }
    
    // Resetar o captor de frames
    self.frameCaptor.lastFrame = nil;
    self.frameCaptor.lastCVPixelBuffer = nil;
    self.frameCaptor.lastI420Buffer = nil;
    
    // Limpar conexão WebSocket
    if (self.webSocketTask) {
        [self.webSocketTask cancel];
        self.webSocketTask = nil;
    }
    
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    
    // Fechar conexão peer
    if (self.peerConnection) {
        [self.peerConnection close];
        self.peerConnection = nil;
    }
    
    // Limpar fábrica
    self.factory = nil;
    
    // Limpar cache de frames
    [self.frameCache removeAllObjects];
    
    self.state = WebRTCManagerStateDisconnected;
}

- (void)sendByeMessage {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning || !self.hasJoinedRoom || self.byeMessageSent) {
        return;
    }
    
    writeLog(@"[WebRTCManager] Enviando mensagem 'bye'");
    
    NSDictionary *byeMessage = @{
        @"type": @"bye",
        @"roomId": self.hasJoinedRoom ? @"ios-camera" : @""
    };
    
    self.byeMessageSent = YES;
    [self sendWebSocketMessage:byeMessage];
}

- (void)setSubstitutionActive:(BOOL)active {
    if (_isSubstitutionActive != active) {
        _isSubstitutionActive = active;
        registerBurladorActive(active);
        writeLog(@"[WebRTCManager] Substituição de câmera %@", active ? @"ativada" : @"desativada");
    }
}

- (void)setUserRequestedDisconnect:(BOOL)requested {
    _userRequestedDisconnect = requested;
}

#pragma mark - Configuração WebRTC

- (void)configureWebRTCWithDefaults {
    // Configurar RTCConfiguration otimizada para rede local
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    
    // Otimização para rede local: usar apenas STUN simples
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
    ];
    
    // Otimizações de transporte
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    config.tcpCandidatePolicy = RTCTcpCandidatePolicyEnabled;
    config.iceCandidatePoolSize = 0; // Otimizado para conexão imediata
    
    // Otimização de candidatos ICE
    config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    
    // Crie as fábricas de codecs
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    // Priorizar H.264 HW para melhor performance
    NSArray<RTCVideoCodecInfo *> *supportedCodecs = [RTCDefaultVideoEncoderFactory supportedCodecs];
    for (RTCVideoCodecInfo *codec in supportedCodecs) {
        if ([codec.name isEqualToString:@"H264"]) {
            [encoderFactory setPreferredCodec:codec];
            break;
        }
    }
    
    // Criar fábrica de conexões
    self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                              decoderFactory:decoderFactory];
    
    // Constraints mínimas
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{}
                                                                            optionalConstraints:@{}];
    
    // Criar conexão peer
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:constraints
                                                              delegate:self];
}

#pragma mark - Conexão WebSocket

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Conectando a: %@", self.serverIP);
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        self.state = WebRTCManagerStateError;
        return;
    }
    
    // Configurar session com maior timeout para estabilidade
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 30.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    
    if (self.session) {
        [self.session invalidateAndCancel];
    }
    
    self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                delegate:self
                                           delegateQueue:[NSOperationQueue mainQueue]];
    
    self.webSocketTask = [self.session webSocketTaskWithURL:url];
    [self receiveWebSocketMessage];
    [self.webSocketTask resume];
    
    // Enviar keepalive periodicamente
    [self performKeepalive];
}

- (void)performKeepalive {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        return;
    }
    
    [self sendWebSocketMessage:@{
        @"type": @"keepalive",
        @"timestamp": @((int)([[NSDate date] timeIntervalSince1970] * 1000))
    }];
    
    // Agendar próximo keepalive
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf performKeepalive];
    });
}

- (void)sendWebSocketMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&error];
    if (error) {
        writeLog(@"[WebRTCManager] Erro ao serializar JSON: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                   completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            if (!weakSelf.userRequestedDisconnect && weakSelf.isSubstitutionActive) {
                // Reconectar automaticamente se necessário
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakSelf.isSubstitutionActive) {
                        [weakSelf connectWebSocket];
                    }
                });
            }
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                     options:0
                                                                       error:&jsonError];
            
            if (!jsonError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf handleWebSocketMessage:jsonDict];
                });
            }
        }
        
        // Continuar recebendo mensagens
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if (!type) {
        return;
    }
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    }
}

#pragma mark - Mensagens SDP

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            return;
        }
        
        // Configurar constraints otimizadas para cliente
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    return;
                }
                
                [weakSelf sendWebSocketMessage:@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": @"ios-camera"
                }];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateConnected;
                });
            }];
        }];
    }];
}

- (void)handleAnswerMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = WebRTCManagerStateConnected;
        });
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        return;
    }
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                           sdpMLineIndex:[sdpMLineIndex intValue]
                                                                  sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao adicionar candidato: %@", error);
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    if (!self.userRequestedDisconnect && !self.hasJoinedRoom) {
        [self sendWebSocketMessage:@{
            @"type": @"join",
            @"roomId": @"ios-camera"
        }];
        
        self.hasJoinedRoom = YES;
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    // Reconectar se necessário
    if (!self.userRequestedDisconnect && self.isSubstitutionActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self connectWebSocket];
        });
    } else {
        self.state = WebRTCManagerStateDisconnected;
        self.hasJoinedRoom = NO;
        self.byeMessageSent = NO;
    }
}

#pragma mark - RTCPeerConnectionDelegate

// Implementação de todos os métodos obrigatórios do protocolo

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    // Nada a fazer aqui, apenas implementando o método exigido pelo protocolo
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    // Nada a fazer aqui, apenas implementando o método exigido pelo protocolo
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    // Nada a fazer aqui, apenas implementando o método exigido pelo protocolo
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    // Nada a fazer aqui, apenas implementando o método exigido pelo protocolo
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    // Nada a fazer aqui, apenas implementando o método exigido pelo protocolo
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        [self.videoTrack addRenderer:self.frameCaptor];
        [self.videoTrack setIsEnabled:YES];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate didReceiveVideoTrack:self.videoTrack];
            self.isReceivingFrames = YES;
            [self.delegate didUpdateConnectionStatus:@"Conectado - Recebendo vídeo"];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        [self.videoTrack removeRenderer:self.frameCaptor];
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    switch (newState) {
        case RTCIceConnectionStateConnected:
        case RTCIceConnectionStateCompleted:
            self.state = WebRTCManagerStateConnected;
            break;
            
        case RTCIceConnectionStateFailed:
        case RTCIceConnectionStateDisconnected:
        case RTCIceConnectionStateClosed:
            if (!self.userRequestedDisconnect) {
                self.state = WebRTCManagerStateError;
            }
            break;
            
        default:
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": @"ios-camera"
    }];
}

#pragma mark - Métodos de Processamento de Frame

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer forceReNew:(BOOL)forceReNew {
    // Se não houver substituição ativa, retorna o buffer original
    if (!self.isSubstitutionActive) {
        return originSampleBuffer;
    }
    
    // Se não estamos recebendo frames, retorna o buffer original
    if (!self.isReceivingFrames || !self.videoTrack) {
        return originSampleBuffer;
    }
    
    __block CMSampleBufferRef result = NULL;
    __block BOOL success = NO;
    
    // Obter e processar o frame em uma fila síncrona para garantir sequência de operações
    dispatch_sync(self.videoQueue, ^{
        @autoreleasepool {
            // Verificar a existência de um frame válido no captor
            RTCVideoFrame *frame = self.frameCaptor.lastFrame;
            if (!frame) {
                return;
            }
            
            // Determinar formato do buffer original para compatibilidade
            OSType targetFormat = kCVPixelFormatType_32BGRA;
            if (originSampleBuffer) {
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
                if (imageBuffer) {
                    targetFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
                }
            }
            
            // Tentar obter o frame convertido do cache
            NSString *cacheKey = [NSString stringWithFormat:@"%lld-%d",
                                 frame.timeStampNs, (int)targetFormat];
            CMSampleBufferRef cachedBuffer = (__bridge CMSampleBufferRef)[self.frameCache objectForKey:cacheKey];
            
            if (cachedBuffer && !forceReNew) {
                // Usar versão em cache se disponível e válida
                if (CMSampleBufferIsValid(cachedBuffer)) {
                    result = (CMSampleBufferRef)CFRetain(cachedBuffer);
                    success = YES;
                    return;
                }
            }
            
            // Não temos cache válido, precisamos criar novo buffer
            
            // 1. Obter o PixelBuffer do frame WebRTC
            CVPixelBufferRef pixelBuffer = NULL;
            if (self.frameCaptor.lastCVPixelBuffer) {
                // Usar CVPixelBuffer diretamente se disponível
                pixelBuffer = CVPixelBufferRetain(self.frameCaptor.lastCVPixelBuffer.pixelBuffer);
            } else if (self.frameCaptor.lastI420Buffer) {
                // Converter de I420 para o formato desejado
                pixelBuffer = [self createPixelBufferFromI420:self.frameCaptor.lastI420Buffer
                                                      format:targetFormat];
            }
            
            if (!pixelBuffer) {
                return;
            }
            
            // 2. Criar o SampleBuffer
            CMSampleBufferRef newBuffer = [self createSampleBufferFromCVPixelBuffer:pixelBuffer
                                                             originSampleBuffer:originSampleBuffer];
            
            CVPixelBufferRelease(pixelBuffer);
            
            if (newBuffer) {
                // Armazenar no cache para reutilização
                [self.frameCache setObject:(__bridge id)newBuffer forKey:cacheKey];
                result = (CMSampleBufferRef)CFRetain(newBuffer);
                CFRelease(newBuffer);
                success = YES;
            }
        }
    });
    
    return success ? result : originSampleBuffer;
}

- (CVPixelBufferRef)createPixelBufferFromI420:(id<RTCI420Buffer>)i420Buffer format:(OSType)format {
    if (!i420Buffer) {
        return NULL;
    }
    
    int width = i420Buffer.width;
    int height = i420Buffer.height;
    
    // Criar pool de buffers se necessário
    if (!self.pixelBufferPool) {
        NSDictionary *poolAttributes = @{
            (NSString*)kCVPixelBufferPoolMinimumBufferCountKey: @(5),
        };
        
        NSDictionary *pixelAttributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(format),
            (NSString*)kCVPixelBufferWidthKey: @(width),
            (NSString*)kCVPixelBufferHeightKey: @(height),
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        
        CVPixelBufferPoolRef newPool = NULL;
        CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                 (__bridge CFDictionaryRef)poolAttributes,
                                                 (__bridge CFDictionaryRef)pixelAttributes,
                                                 &newPool);
        
        if (status == kCVReturnSuccess && newPool) {
            if (self.pixelBufferPool) {
                CVPixelBufferPoolRelease(self.pixelBufferPool);
            }
            self.pixelBufferPool = newPool;
        } else {
            return NULL;
        }
    }
    
    // Obter buffer do pool
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                        self.pixelBufferPool,
                                                        &pixelBuffer);
    
    if (status != kCVReturnSuccess || !pixelBuffer) {
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Converter o conteúdo de I420 para o formato desejado
    if (format == kCVPixelFormatType_32BGRA) {
        // Versão otimizada para BGRA com lookup tables
        [self convertI420ToBGRA:i420Buffer toPixelBuffer:pixelBuffer];
    }
    else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
             format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        // Conversão para formatos NV12/NV21
        [self convertI420ToBiPlanar:i420Buffer toPixelBuffer:pixelBuffer];
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

- (void)convertI420ToBGRA:(id<RTCI420Buffer>)i420Buffer toPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // Otimização: usar tabelas pré-calculadas para conversão YUV -> RGB
    static int16_t yTable[256], uTable[256], vTable[256];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (int i = 0; i < 256; i++) {
            yTable[i] = (int16_t)(1.164 * (i - 16) * 64);
            int value = i - 128;
            uTable[i] = (int16_t)(2.018 * value * 64);
            vTable[i] = (int16_t)(1.596 * value * 64);
        }
    });
    
    int width = i420Buffer.width;
    int height = i420Buffer.height;
    
    const uint8_t *srcY = i420Buffer.dataY;
    const uint8_t *srcU = i420Buffer.dataU;
    const uint8_t *srcV = i420Buffer.dataV;
    
    int srcStrideY = i420Buffer.strideY;
    int srcStrideU = i420Buffer.strideU;
    int srcStrideV = i420Buffer.strideV;
    
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // Algoritmo otimizado com tabelas lookup
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int yIndex = y * srcStrideY + x;
            int uIndex = (y / 2) * srcStrideU + (x / 2);
            int vIndex = (y / 2) * srcStrideV + (x / 2);
            
            int Y = srcY[yIndex];
            int U = srcU[uIndex];
            int V = srcV[vIndex];
            
            int yComp = yTable[Y];
            int uComp = uTable[U];
            int vComp = vTable[V];
            
            // Conversão para BGRA
            int dstIndex = y * dstStride + x * 4;
            // B = Y + 2.018 * (U - 128)
            dst[dstIndex + 0] = clip((yComp + uComp) >> 6);
            // G = Y - 0.391 * (U - 128) - 0.813 * (V - 128)
            dst[dstIndex + 1] = clip((yComp - ((uComp + vComp) >> 2)) >> 6);
            // R = Y + 1.596 * (V - 128)
            dst[dstIndex + 2] = clip((yComp + vComp) >> 6);
            // A = 255
            dst[dstIndex + 3] = 255;
        }
    }
}

// Auxiliar para clamp de valores entre 0-255
static inline uint8_t clip(int value) {
    return (uint8_t)(value < 0 ? 0 : (value > 255 ? 255 : value));
}

- (void)convertI420ToBiPlanar:(id<RTCI420Buffer>)i420Buffer toPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    int width = i420Buffer.width;
    int height = i420Buffer.height;
    
    const uint8_t *srcY = i420Buffer.dataY;
    const uint8_t *srcU = i420Buffer.dataU;
    const uint8_t *srcV = i420Buffer.dataV;
    
    int srcStrideY = i420Buffer.strideY;
    int srcStrideU = i420Buffer.strideU;
    int srcStrideV = i420Buffer.strideV;
    
    // Processar plano Y
    uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    
    for (int y = 0; y < height; y++) {
        memcpy(dstY + y * dstStrideY, srcY + y * srcStrideY, width);
    }
    
    // Processar plano UV (intercalado)
    uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    
    int chromaHeight = height / 2;
    int chromaWidth = width / 2;
    
    for (int y = 0; y < chromaHeight; y++) {
        for (int x = 0; x < chromaWidth; x++) {
            dstUV[y * dstStrideUV + x * 2] = srcU[y * srcStrideU + x];
            dstUV[y * dstStrideUV + x * 2 + 1] = srcV[y * srcStrideV + x];
        }
    }
}

- (CMSampleBufferRef)createSampleBufferFromCVPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                   originSampleBuffer:(CMSampleBufferRef)originSampleBuffer {
    if (!pixelBuffer) {
        return NULL;
    }
    
    // Criar descrição de formato de vídeo para o buffer
    CMVideoFormatDescriptionRef videoInfo = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                  pixelBuffer,
                                                                  &videoInfo);
    
    if (status != noErr) {
        return NULL;
    }
    
    // Obter informações de timing do buffer original ou criar novo
    CMSampleTimingInfo timing;
    
    if (originSampleBuffer) {
        timing.duration = CMSampleBufferGetDuration(originSampleBuffer);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);
        timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer);
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 90000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }
    
    // Criar o sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                               pixelBuffer,
                                               YES,
                                               NULL,
                                               NULL,
                                               videoInfo,
                                               &timing,
                                               &sampleBuffer);
    
    CFRelease(videoInfo);
    
    return (status == noErr) ? sampleBuffer : NULL;
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        stats[@"connectionState"] = @(self.state);
        stats[@"iceState"] = @(self.peerConnection.iceConnectionState);
        stats[@"isReceivingFrames"] = @(self.isReceivingFrames);
        stats[@"isSubstitutionActive"] = @(self.isSubstitutionActive);
        
        // Informações do frame atual
        if (self.frameCaptor.lastFrame) {
            stats[@"frameWidth"] = @(self.frameCaptor.lastFrame.width);
            stats[@"frameHeight"] = @(self.frameCaptor.lastFrame.height);
            stats[@"frameRotation"] = @(self.frameCaptor.lastFrame.rotation);
        }
    }
    
    return stats;
}

@end
