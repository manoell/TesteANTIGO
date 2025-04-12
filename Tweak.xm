#import "FloatingWindow.h"
#import "logger.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>

// Declaração da classe WebRTCFrameProvider
@interface WebRTCFrameProvider : NSObject <RTCVideoRenderer, RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
+ (instancetype)sharedInstance;
- (void)startWebRTC;
- (void)stopWebRTC;
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer forceReNew:(BOOL)forceReNew;
- (void)setSubstitutionActive:(BOOL)active;
- (BOOL)isConnected;
- (BOOL)isReceivingFrames;
- (void)addVideoTrack:(RTCVideoTrack *)videoTrack;

@property(nonatomic, assign) BOOL isSubstitutionActive;
@property(nonatomic, strong) RTCPeerConnection *peerConnection;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) RTCVideoTrack *videoTrack;
@property(nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSString *roomId;
@property(nonatomic, assign) BOOL hasJoinedRoom;
@property(nonatomic, assign) RTCVideoRotation lastRotation;
@property(nonatomic, weak) FloatingWindow *floatingWindow; // Referência fraca para a FloatingWindow
@end

// Variáveis globais para gerenciamento de recursos
static FloatingWindow *g_floatingWindow = nil;
static WebRTCFrameProvider *g_frameProvider = nil;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;
static AVCaptureVideoOrientation g_lastOrientation = AVCaptureVideoOrientationPortrait;
static NSString *g_serverIP = @"192.168.0.178";
static BOOL g_cameraRunning = NO;
static BOOL g_isSubstitutionActive = NO;

// Garantir que as variáveis globais estejam inicializadas corretamente
static void initializeGlobalVariables() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        writeLog(@"Inicializando variáveis globais para substituição de câmera");
        
        // Verificar e inicializar o frameProvider
        if (g_frameProvider == nil) {
            g_frameProvider = [WebRTCFrameProvider sharedInstance];
            writeLog(@"g_frameProvider inicializado: %@", g_frameProvider ? @"OK" : @"FALHA");
        }
        
        // Verificar estado do burlador ao iniciar
        BOOL burladorActive = g_isSubstitutionActive;
        writeLog(@"Estado inicial do burlador: %@", burladorActive ? @"ATIVO" : @"INATIVO");
        
        // Resetar para garantir estado inicial consistente
        g_isSubstitutionActive = NO;
    });
}

#pragma mark - WebRTCFrameProvider Implementation

@implementation WebRTCFrameProvider {
    CMSampleBufferRef _currentFrameBuffer;
    dispatch_queue_t _processingQueue;
    NSLock *_frameLock;
    RTCVideoFrame *_lastCapturedFrame;
    id<RTCI420Buffer> _lastI420Buffer;
    RTCCVPixelBuffer *_lastCVPixelBuffer;
    NSTimeInterval _lastFrameTime;
    int _frameCounter;
    NSTimeInterval _lastErrorLogTime;
    BOOL _hasLoggedFrameError;
}

+ (instancetype)sharedInstance {
    static WebRTCFrameProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isSubstitutionActive = NO;
        _roomId = @"ios-camera";
        _hasJoinedRoom = NO;
        _currentFrameBuffer = NULL;
        _lastCapturedFrame = nil;
        _lastI420Buffer = nil;
        _lastCVPixelBuffer = nil;
        _lastFrameTime = 0;
        _frameCounter = 0;
        _hasLoggedFrameError = NO;
        _lastErrorLogTime = 0;
        _lastRotation = RTCVideoRotation_0;
        _frameLock = [[NSLock alloc] init];
        _processingQueue = dispatch_queue_create("com.webrtc.frameProvider", DISPATCH_QUEUE_SERIAL);
        
        writeLog(@"[WebRTCFrameProvider] Inicializado");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC];
    [self releaseCurrentFrame];
}

- (void)releaseCurrentFrame {
    [_frameLock lock];
    if (_currentFrameBuffer) {
        CFRelease(_currentFrameBuffer);
        _currentFrameBuffer = NULL;
    }
    [_frameLock unlock];
    
    _lastCapturedFrame = nil;
    _lastI420Buffer = nil;
    _lastCVPixelBuffer = nil;
}

#pragma mark - WebRTC Methods

- (void)startWebRTC {
    if (self.peerConnection) {
        writeLog(@"[WebRTCFrameProvider] Já existe uma conexão ativa");
        return;
    }
    
    writeLog(@"[WebRTCFrameProvider] Iniciando conexão WebRTC");
    
    // Atualização de status para a UI
    if (self.floatingWindow) {
        [self.floatingWindow updateConnectionStatus:@"Conectando..."];
    }
    
    // Configuração do RTCPeerConnection
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
    ];
    
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
        initWithMandatoryConstraints:@{}
        optionalConstraints:@{}];
    
    // Criar fábricas de codec com suporte a hardware
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    // Priorizar H.264 para melhor desempenho
    if (encoderFactory.supportedCodecs.count > 0) {
        NSMutableArray<RTCVideoCodecInfo *> *supportedCodecs = [NSMutableArray array];
        
        // Adicionar H.264 primeiro
        for (RTCVideoCodecInfo *codec in encoderFactory.supportedCodecs) {
            if ([codec.name isEqualToString:@"H264"]) {
                [supportedCodecs addObject:codec];
            }
        }
        
        // Adicionar os demais codecs
        for (RTCVideoCodecInfo *codec in encoderFactory.supportedCodecs) {
            if (![codec.name isEqualToString:@"H264"]) {
                [supportedCodecs addObject:codec];
            }
        }
        
        if (supportedCodecs.count > 0) {
            encoderFactory.preferredCodec = supportedCodecs.firstObject;
        }
    }
    
    // Criar factory e peer connection
    self.factory = [[RTCPeerConnectionFactory alloc]
        initWithEncoderFactory:encoderFactory
        decoderFactory:decoderFactory];
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:constraints
                                                              delegate:self];
    
    if (self.peerConnection) {
        writeLog(@"[WebRTCFrameProvider] PeerConnection criado com sucesso");
        
        // Iniciar conexão WebSocket
        [self connectWebSocket];
    } else {
        writeLog(@"[WebRTCFrameProvider] Falha ao criar PeerConnection");
        if (self.floatingWindow) {
            [self.floatingWindow updateConnectionStatus:@"Falha ao criar conexão"];
        }
    }
}

- (void)stopWebRTC {
    // Liberar recursos de WebRTC
    writeLog(@"[WebRTCFrameProvider] Parando conexão WebRTC");
    
    // Atualização de status para a UI
    if (self.floatingWindow) {
        [self.floatingWindow updateConnectionStatus:@"Desconectando..."];
    }
    
    // Enviar mensagem de despedida se estiver em uma sala
    if (self.webSocketTask && self.hasJoinedRoom) {
        [self sendByeMessage];
    }
    
    // Fechar conexão WebSocket
    if (self.webSocketTask) {
        [self.webSocketTask cancel];
        self.webSocketTask = nil;
    }
    
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    
    // Fechar peer connection
    if (self.peerConnection) {
        [self.peerConnection close];
        self.peerConnection = nil;
    }
    
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self];
        self.videoTrack = nil;
    }
    
    self.factory = nil;
    self.hasJoinedRoom = NO;
    
    // Liberar buffer de frame atual
    [self releaseCurrentFrame];
    
    // Atualização final de status
    if (self.floatingWindow) {
        [self.floatingWindow updateConnectionStatus:@"Desconectado"];
    }
}

- (void)connectWebSocket {
    writeLog(@"[WebRTCFrameProvider] Conectando ao servidor WebSocket");
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", g_serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        writeLog(@"[WebRTCFrameProvider] URL inválida");
        if (self.floatingWindow) {
            [self.floatingWindow updateConnectionStatus:@"URL inválida"];
        }
        return;
    }
    
    // Configuração de timeout para conexões em rede local
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 30.0;
    sessionConfig.timeoutIntervalForResource = 60.0;
    
    if (self.session) {
        [self.session invalidateAndCancel];
    }
    
    self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                 delegate:self
                                            delegateQueue:[NSOperationQueue mainQueue]];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    self.webSocketTask = [self.session webSocketTaskWithRequest:request];
    
    [self receiveWebSocketMessage];
    [self.webSocketTask resume];
    
    // Configurar timer para keepalive (opcional)
    [self setupKeepAliveTimer];
}

- (void)setupKeepAliveTimer {
    // Implementar se necessário para manter a conexão WebSocket ativa
}

- (void)sendWebSocketMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCFrameProvider] WebSocket não está conectado");
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                       options:0
                                                         error:&error];
    if (error) {
        writeLog(@"[WebRTCFrameProvider] Erro ao serializar mensagem: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                  completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCFrameProvider] Erro ao enviar mensagem: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (error) {
            writeLog(@"[WebRTCFrameProvider] Erro ao receber mensagem: %@", error);
            
            // Tentar reconectar se o erro for de rede e o WebSocket não estiver em execução
            if (!weakSelf.webSocketTask || weakSelf.webSocketTask.state != NSURLSessionTaskStateRunning) {
                if (weakSelf.isSubstitutionActive) {
                    if (weakSelf.floatingWindow) {
                        [weakSelf.floatingWindow updateConnectionStatus:@"Reconectando..."];
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf connectWebSocket];
                    });
                }
            }
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *jsonData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                     options:0
                                                                       error:&jsonError];
            
            if (jsonError) {
                writeLog(@"[WebRTCFrameProvider] Erro ao analisar JSON: %@", jsonError);
                return;
            }
            
            // Processar a mensagem na thread principal
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        
        // Continuar recebendo mensagens se o WebSocket estiver ativo
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if (!type) {
        writeLog(@"[WebRTCFrameProvider] Mensagem sem tipo recebida");
        return;
    }
    
    writeLog(@"[WebRTCFrameProvider] Mensagem recebida: %@", type);
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    } else if ([type isEqualToString:@"user-joined"]) {
        writeLog(@"[WebRTCFrameProvider] Usuário entrou na sala: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"user-left"]) {
        writeLog(@"[WebRTCFrameProvider] Usuário saiu da sala: %@", message[@"userId"]);
    }
}

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCFrameProvider] Recebeu oferta sem PeerConnection");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCFrameProvider] Oferta sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCFrameProvider] Erro ao definir descrição remota: %@", error);
            return;
        }
        
        // Criar resposta
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                                    completionHandler:^(RTCSessionDescription *sdp, NSError *error) {
            if (error) {
                writeLog(@"[WebRTCFrameProvider] Erro ao criar resposta: %@", error);
                return;
            }
            
            // Otimizar SDP para alta qualidade
            NSString *optimizedSdp = [weakSelf optimizeSdpForHighQuality:sdp.sdp];
            RTCSessionDescription *optimizedDescription = [[RTCSessionDescription alloc]
                                                          initWithType:RTCSdpTypeAnswer
                                                          sdp:optimizedSdp];
            
            [weakSelf.peerConnection setLocalDescription:optimizedDescription completionHandler:^(NSError *error) {
                if (error) {
                    writeLog(@"[WebRTCFrameProvider] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                // Enviar resposta
                [weakSelf sendWebSocketMessage:@{
                    @"type": @"answer",
                    @"sdp": optimizedDescription.sdp,
                    @"roomId": weakSelf.roomId
                }];
                
                writeLog(@"[WebRTCFrameProvider] Resposta enviada com sucesso");
            }];
        }];
    }];
}

- (void)handleAnswerMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCFrameProvider] Recebeu resposta sem PeerConnection");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCFrameProvider] Resposta sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCFrameProvider] Erro ao definir descrição remota (resposta): %@", error);
            return;
        }
        
        writeLog(@"[WebRTCFrameProvider] Resposta processada com sucesso");
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCFrameProvider] Recebeu candidato sem PeerConnection");
        return;
    }
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        writeLog(@"[WebRTCFrameProvider] Candidato com parâmetros inválidos");
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                           sdpMLineIndex:[sdpMLineIndex intValue]
                                                                  sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError *error) {
        if (error) {
            writeLog(@"[WebRTCFrameProvider] Erro ao adicionar candidato Ice: %@", error);
        }
    }];
}

- (NSString *)optimizeSdpForHighQuality:(NSString *)sdp {
    // Otimiza o SDP para streaming de alta qualidade em redes locais
    if (!sdp) return nil;
    
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:[sdp componentsSeparatedByString:@"\n"]];
    BOOL inVideoSection = NO;
    BOOL videoSectionModified = NO;
    
    for (NSInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        
        // Detectar seção de vídeo
        if ([line hasPrefix:@"m=video"]) {
            inVideoSection = YES;
        } else if ([line hasPrefix:@"m="]) {
            inVideoSection = NO;
        }
        
        // Para seção de vídeo, adicionar configurações de alta qualidade
        if (inVideoSection && [line hasPrefix:@"c="] && !videoSectionModified) {
            // Alta taxa de bits para 4K
            [lines insertObject:@"b=AS:20000" atIndex:i + 1];
            i++; // Avançar índice
            videoSectionModified = YES;
        }
        
        // Configurar profile H.264 para 4K
        if (inVideoSection && [line containsString:@"profile-level-id"] && [line containsString:@"H264"]) {
            if (![line containsString:@"profile-level-id=640032"]) {
                lines[i] = [line stringByReplacingOccurrencesOfString:@"profile-level-id=[0-9a-fA-F]+"
                                                           withString:@"profile-level-id=640032"
                                                              options:NSRegularExpressionSearch
                                                                range:NSMakeRange(0, line.length)];
            }
        }
    }
    
    return [lines componentsJoinedByString:@"\n"];
}

- (void)sendByeMessage {
    if (!self.webSocketTask || !self.hasJoinedRoom) {
        return;
    }
    
    writeLog(@"[WebRTCFrameProvider] Enviando bye");
    
    [self sendWebSocketMessage:@{
        @"type": @"bye",
        @"roomId": self.roomId
    }];
}

#pragma mark - RTCVideoRenderer Methods

- (void)renderFrame:(RTCVideoFrame *)frame {
    // Este método é chamado quando recebemos um novo frame do WebRTC
    @synchronized(self) {
        _lastCapturedFrame = frame;
        _lastI420Buffer = nil;
        _lastCVPixelBuffer = nil;
        _lastFrameTime = CACurrentMediaTime();
        _lastRotation = frame.rotation;
        
        // Salvar o formato do buffer para uso posterior
        if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            _lastCVPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
        } else {
            // Converter para I420 se não for CVPixelBuffer
            _lastI420Buffer = [frame.buffer toI420];
        }
    }
}

- (void)setSize:(CGSize)size {
    // Método obrigatório do protocolo RTCVideoRenderer
    // Não precisamos fazer nada aqui
}

- (BOOL)isConnected {
    return (self.peerConnection != nil &&
            self.webSocketTask != nil &&
            self.webSocketTask.state == NSURLSessionTaskStateRunning);
}

- (BOOL)isReceivingFrames {
    return (_lastCapturedFrame != nil &&
            (CACurrentMediaTime() - _lastFrameTime) < 1.0); // Frame nos últimos 1s
}

- (void)addVideoTrack:(RTCVideoTrack *)videoTrack {
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self];
    }
    
    self.videoTrack = videoTrack;
    
    if (videoTrack) {
        [videoTrack addRenderer:self];
        [videoTrack setIsEnabled:YES];
        writeLog(@"[WebRTCFrameProvider] Video track adicionado: %@", videoTrack.trackId);
        
        // Notificar FloatingWindow que recebemos um videoTrack
        if (self.floatingWindow) {
            [self.floatingWindow didReceiveVideoTrack:videoTrack];
        }
    }
}

- (void)setSubstitutionActive:(BOOL)active {
    if (_isSubstitutionActive != active) {
        _isSubstitutionActive = active;
        writeLog(@"[WebRTCFrameProvider] Substituição %@", active ? @"ativada" : @"desativada");
        
        // Substituir a chamada de registerBurladorActive por uma atribuição direta à variável global
        g_isSubstitutionActive = active;
        writeLog(@"[Global] Estado do burlador alterado para: %@", active ? @"ATIVO" : @"INATIVO");
        
        // Iniciar ou parar WebRTC conforme o estado
        if (active && !self.peerConnection) {
            [self startWebRTC];
        } else if (!active && self.peerConnection) {
            [self stopWebRTC];
        }
        
        // Resetar contadores de log
        _hasLoggedFrameError = NO;
    }
}

#pragma mark - Frame Processing Methods

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer forceReNew:(BOOL)forceReNew {
    // Incrementar contador para controle de log
    _frameCounter++;
    BOOL shouldLog = (_frameCounter % 100 == 0); // Aumentei a frequência de log para debug
    
    if (shouldLog) {
        writeLog(@"[WebRTCFrameProvider] getCurrentFrame (#%d) - %@",
                _frameCounter, self.isReceivingFrames ? @"recebendo frames" : @"sem frames");
    }
    
    // Verificação primária: substituição deve estar ativa
    if (!self.isSubstitutionActive) {
        return originSampleBuffer;
    }
    
    // Verificar se temos frames disponíveis e conexão ativa
    if (!self.isReceivingFrames || !self.videoTrack) {
        NSTimeInterval currentTime = CACurrentMediaTime();
        if (!_hasLoggedFrameError || (currentTime - _lastErrorLogTime) > 2.0) {
            writeLog(@"[WebRTCFrameProvider] Sem frames para substituição (isReceivingFrames: %d, videoTrack: %@)",
                   self.isReceivingFrames, self.videoTrack ? @"OK" : @"NULL");
            _hasLoggedFrameError = YES;
            _lastErrorLogTime = currentTime;
        }
        return originSampleBuffer; // Retorna buffer original se não temos frames
    }
    
    // Obter o formato do buffer original
    OSType targetFormat = kCVPixelFormatType_32BGRA; // Formato padrão
    CVImageBufferRef originalImageBuffer = NULL;
    
    if (originSampleBuffer) {
        originalImageBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
        if (originalImageBuffer) {
            targetFormat = CVPixelBufferGetPixelFormatType(originalImageBuffer);
            if (shouldLog) {
                writeLog(@"[WebRTCFrameProvider] Formato do buffer original: %d", (int)targetFormat);
            }
        }
    }
    
    // Tentar obter frame do WebRTC - Primeiro RTCCVPixelBuffer (mais direto)
    @synchronized(self) {
        if (_lastCVPixelBuffer && _lastCVPixelBuffer.pixelBuffer) {
            CVPixelBufferRef pixelBuffer = _lastCVPixelBuffer.pixelBuffer;
            
            // Debug info
            if (shouldLog) {
                writeLog(@"[WebRTCFrameProvider] Usando CVPixelBuffer direto: %dx%d, formato %d",
                        (int)CVPixelBufferGetWidth(pixelBuffer),
                        (int)CVPixelBufferGetHeight(pixelBuffer),
                        (int)CVPixelBufferGetPixelFormatType(pixelBuffer));
            }
            
            // Verificar se o formato corresponde ao alvo
            OSType currentFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
            
            // Converter para o formato alvo se necessário
            if (currentFormat != targetFormat) {
                CVPixelBufferRef convertedBuffer = [self convertPixelBuffer:pixelBuffer toFormat:targetFormat];
                if (convertedBuffer) {
                    CMSampleBufferRef newBuffer = [self createSampleBufferFromPixelBuffer:convertedBuffer
                                                                  originSampleBuffer:originSampleBuffer];
                    CVPixelBufferRelease(convertedBuffer);
                    if (newBuffer) {
                        if (shouldLog) {
                            writeLog(@"[WebRTCFrameProvider] Frame convertido com sucesso");
                        }
                        return newBuffer;
                    }
                }
            } else {
                // Mesmo formato, criar diretamente
                CMSampleBufferRef newBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer
                                                               originSampleBuffer:originSampleBuffer];
                if (newBuffer) {
                    if (shouldLog) {
                        writeLog(@"[WebRTCFrameProvider] Frame criado sem conversão");
                    }
                    return newBuffer;
                }
            }
        }
        
        // Alternativa: usar I420Buffer
        if (_lastI420Buffer) {
            if (shouldLog) {
                writeLog(@"[WebRTCFrameProvider] Tentando usar I420Buffer: %dx%d",
                       (int)_lastI420Buffer.width, (int)_lastI420Buffer.height);
            }
            
            CVPixelBufferRef newPixelBuffer = [self createCVPixelBufferFromI420:_lastI420Buffer format:targetFormat];
            if (newPixelBuffer) {
                CMSampleBufferRef resultBuffer = [self createSampleBufferFromPixelBuffer:newPixelBuffer
                                                                originSampleBuffer:originSampleBuffer];
                CVPixelBufferRelease(newPixelBuffer);
                
                if (resultBuffer) {
                    if (shouldLog) {
                        writeLog(@"[WebRTCFrameProvider] Frame criado de I420Buffer");
                    }
                    return resultBuffer;
                }
            }
        }
    }
    
    // Último recurso: se temos um frame capturado mas não conseguimos convertê-lo
    if (_lastCapturedFrame && shouldLog) {
        writeLog(@"[WebRTCFrameProvider] Temos frame mas falha na conversão: %dx%d",
                (int)_lastCapturedFrame.width, (int)_lastCapturedFrame.height);
    }
    
    // Se tudo falhar, retornar o buffer original
    if (shouldLog) {
        writeLog(@"[WebRTCFrameProvider] Retornando buffer original");
    }
    return originSampleBuffer;
}

- (CVPixelBufferRef)convertPixelBuffer:(CVPixelBufferRef)sourceBuffer toFormat:(OSType)targetFormat {
    if (!sourceBuffer) return NULL;
    
    size_t width = CVPixelBufferGetWidth(sourceBuffer);
    size_t height = CVPixelBufferGetHeight(sourceBuffer);
    
    // Criar novo buffer no formato alvo
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *pixelAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(targetFormat),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height, targetFormat,
                                         (__bridge CFDictionaryRef)pixelAttributes,
                                         &pixelBuffer);
    
    if (status != kCVReturnSuccess || !pixelBuffer) {
        writeLog(@"[WebRTCFrameProvider] Falha ao criar pixel buffer: %d", (int)status);
        return NULL;
    }
    
    // Implementar conversão com base nos formatos de origem e destino
    // (Podemos expandir isto para mais formatos conforme necessário)
    
    return pixelBuffer;
}

- (CVPixelBufferRef)createCVPixelBufferFromI420:(id<RTCI420Buffer>)i420Buffer format:(OSType)format {
    if (!i420Buffer) return NULL;
    
    int width = i420Buffer.width;
    int height = i420Buffer.height;
    
    writeLog(@"[WebRTCFrameProvider] Convertendo I420Buffer %dx%d para formato %d", width, height, (int)format);
    
    // Criar CVPixelBuffer
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *pixelAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(format),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferOpenGLCompatibilityKey: @YES,
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width, height, format,
                                         (__bridge CFDictionaryRef)pixelAttributes,
                                         &pixelBuffer);
    
    if (status != kCVReturnSuccess || !pixelBuffer) {
        writeLog(@"[WebRTCFrameProvider] Falha ao criar CVPixelBuffer: %d", (int)status);
        return NULL;
    }
    
    // Converter I420 para o formato desejado
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Implementar conversão de acordo com o formato alvo
    if (format == kCVPixelFormatType_32BGRA) {
        // Converter I420 para BGRA
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
        const uint8_t *srcY = i420Buffer.dataY;
        const uint8_t *srcU = i420Buffer.dataU;
        const uint8_t *srcV = i420Buffer.dataV;
        int srcStrideY = i420Buffer.strideY;
        int srcStrideU = i420Buffer.strideU;
        int srcStrideV = i420Buffer.strideV;
        
        // Conversão YUV -> RGB
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int yIndex = y * srcStrideY + x;
                int uIndex = (y / 2) * srcStrideU + (x / 2);
                int vIndex = (y / 2) * srcStrideV + (x / 2);
                
                int Y = srcY[yIndex];
                int U = srcU[uIndex];
                int V = srcV[vIndex];
                
                // Ajuste de escala YUV [16..235] -> [0..255]
                Y = Y - 16;
                U = U - 128;
                V = V - 128;
                
                // Conversão YUV para RGB
                int r = (298 * Y + 409 * V + 128) >> 8;
                int g = (298 * Y - 100 * U - 208 * V + 128) >> 8;
                int b = (298 * Y + 516 * U + 128) >> 8;
                
                // Clamp para [0..255]
                r = r < 0 ? 0 : (r > 255 ? 255 : r);
                g = g < 0 ? 0 : (g > 255 ? 255 : g);
                b = b < 0 ? 0 : (b > 255 ? 255 : b);
                
                // Escrever no buffer BGRA
                int destIdx = y * dstStride + x * 4;
                dst[destIdx + 0] = b;  // B
                dst[destIdx + 1] = g;  // G
                dst[destIdx + 2] = r;  // R
                dst[destIdx + 3] = 255; // A
            }
        }
    }
    else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
             format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        // Converter I420 para NV12/NV21 (BiPlanar)
        uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        
        size_t dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        size_t dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        
        const uint8_t *srcY = i420Buffer.dataY;
        const uint8_t *srcU = i420Buffer.dataU;
        const uint8_t *srcV = i420Buffer.dataV;
        int srcStrideY = i420Buffer.strideY;
        int srcStrideU = i420Buffer.strideU;
        int srcStrideV = i420Buffer.strideV;
        
        // Copiar plano Y
        for (int y = 0; y < height; y++) {
            memcpy(dstY + y * dstStrideY, srcY + y * srcStrideY, width);
        }
        
        // Preencher plano UV intercalado
        for (int y = 0; y < height / 2; y++) {
            for (int x = 0; x < width / 2; x++) {
                dstUV[y * dstStrideUV + x * 2] = srcU[y * srcStrideU + x];
                dstUV[y * dstStrideUV + x * 2 + 1] = srcV[y * srcStrideV + x];
            }
        }
    } else {
        writeLog(@"[WebRTCFrameProvider] Formato pixel não suportado: %d", (int)format);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                    originSampleBuffer:(CMSampleBufferRef)originSampleBuffer {
    if (!pixelBuffer) {
        return NULL;
    }
    
    // Criar descrição de formato
    CMVideoFormatDescriptionRef videoInfo = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &videoInfo);
    
    if (status != noErr) {
        writeLog(@"[WebRTCFrameProvider] Falha ao criar descrição de formato: %d", (int)status);
        return NULL;
    }
    
    // Obter timing info do buffer original ou criar novo
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
    
    // Criar sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        true,
        NULL,
        NULL,
        videoInfo,
        &timing,
        &sampleBuffer);
    
    // Liberar recursos
    CFRelease(videoInfo);
    
    if (status != noErr) {
        writeLog(@"[WebRTCFrameProvider] Falha ao criar sample buffer: %d", (int)status);
        return NULL;
    }
    
    return sampleBuffer;
}

#pragma mark - RTCPeerConnectionDelegate Methods

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    writeLog(@"[WebRTCFrameProvider] Signaling state changed: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCFrameProvider] Stream added: %@", stream.streamId);
    
    // Verificar se tem trilha de vídeo
    if (stream.videoTracks.count > 0) {
        RTCVideoTrack *videoTrack = stream.videoTracks[0];
        [self addVideoTrack:videoTrack]; // Isso chamará didReceiveVideoTrack via floatingWindow
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCFrameProvider] Stream removed: %@", stream.streamId);
    
    // Limpar o video track se foi removido
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        [self.videoTrack removeRenderer:self];
        self.videoTrack = nil;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCFrameProvider] Should negotiate");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    writeLog(@"[WebRTCFrameProvider] ICE connection state changed: %ld", (long)newState);
    
    // Notificar a FloatingWindow sobre mudanças de estado
    if (self.floatingWindow) {
        NSString *status = nil;
        
        switch (newState) {
            case RTCIceConnectionStateConnected:
                status = @"Conectado";
                break;
            case RTCIceConnectionStateCompleted:
                status = @"Conexão completa";
                break;
            case RTCIceConnectionStateDisconnected:
                status = @"Desconectado";
                break;
            case RTCIceConnectionStateFailed:
                status = @"Falha na conexão";
                break;
            case RTCIceConnectionStateClosed:
                status = @"Conexão fechada";
                break;
            default:
                break;
        }
        
        if (status) {
            [self.floatingWindow updateConnectionStatus:status];
        }
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    writeLog(@"[WebRTCFrameProvider] ICE gathering state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCFrameProvider] ICE candidate generated");
    
    // Enviar o candidato ICE para o servidor
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCFrameProvider] ICE candidates removed: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCFrameProvider] Data channel opened: %@", dataChannel.label);
}

#pragma mark - NSURLSessionWebSocketDelegate Methods

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCFrameProvider] WebSocket conectado");
    
    // Entrar na sala
    self.roomId = self.roomId ?: @"ios-camera";
    [self sendWebSocketMessage:@{
        @"type": @"join",
        @"roomId": self.roomId
    }];
    
    self.hasJoinedRoom = YES;
    writeLog(@"[WebRTCFrameProvider] Entrou na sala: %@", self.roomId);
    
    // Atualizar status na UI
    if (self.floatingWindow) {
        [self.floatingWindow updateConnectionStatus:@"Conectado ao servidor"];
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCFrameProvider] WebSocket fechou com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    
    // Atualizar status na UI
    if (self.floatingWindow) {
        [self.floatingWindow updateConnectionStatus:@"WebSocket fechou"];
    }
    
    // Tentar reconectar se a substituição estiver ativa
    if (self.isSubstitutionActive) {
        if (self.floatingWindow) {
            [self.floatingWindow updateConnectionStatus:@"Reconectando..."];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self connectWebSocket];
        });
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCFrameProvider] WebSocket falhou com erro: %@", error);
        
        // Atualizar status na UI
        if (self.floatingWindow) {
            [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", error.localizedDescription]];
        }
        
        // Tentar reconectar se a substituição estiver ativa
        if (self.isSubstitutionActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.floatingWindow) {
                    [self.floatingWindow updateConnectionStatus:@"Reconectando..."];
                }
                [self connectWebSocket];
            });
        }
    }
}

@end

#pragma mark - Hook Implementations

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
-(void)step:(CADisplayLink *)sender{
    // Usar a variável global em vez da função isBurladorActive
    BOOL isSubstitutionActive = g_isSubstitutionActive;
    
    // Cache de verificação para evitar sobrecarga
    static NSTimeInterval lastLogTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    static int frameCounter = 0;
    
    // Log a cada 3 segundos ou a cada 100 frames, o que ocorrer primeiro
    BOOL shouldLog = (currentTime - lastLogTime > 3.0) || (++frameCounter % 100 == 0);
    
    if (shouldLog) {
        writeLog(@"[step] Estado burlador: %@, camadas: mask=%@, preview=%@, contador=%d, global=%d",
                isSubstitutionActive ? @"ATIVO" : @"INATIVO",
                g_maskLayer ? @"OK" : @"NULL",
                g_previewLayer ? @"OK" : @"NULL",
                frameCounter,
                g_isSubstitutionActive);
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
            
            writeLog(@"[step] Atualizando orientação para: %d", (int)g_photoOrientation);
            
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

        // Tentar obter frame para preview apenas se estiver pronto para receber mais dados
        if (g_previewLayer.readyForMoreMediaData) {
            // Verificar se WebRTCFrameProvider está disponível
            if (g_frameProvider) {
                // Obtém o próximo frame
                CMSampleBufferRef newBuffer = nil;
                
                // Verificar o tipo de chamada para tentar obter um frame manualmente
                @try {
                    newBuffer = [g_frameProvider getCurrentFrame:nil forceReNew:YES];
                } @catch (NSException *exception) {
                    writeLog(@"[step] Erro ao obter frame: %@", exception);
                }
                
                // Log mais frequente para frames
                if (shouldLog) {
                    writeLog(@"[step] Tentativa de obter frame: %@", newBuffer ? @"Sucesso" : @"Falha");
                }
                
                if (newBuffer != nil) {
                    // Limpa quaisquer frames na fila
                    [g_previewLayer flush];
                    
                    // Adiciona o novo frame
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                    
                    // Log ocasional para confirmar que frames estão sendo adicionados
                    if (shouldLog) {
                        writeLog(@"[step] Frame adicionado à camada");
                        
                        // Analisar o buffer para debug
                        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                        if (imageBuffer) {
                            size_t width = CVPixelBufferGetWidth(imageBuffer);
                            size_t height = CVPixelBufferGetHeight(imageBuffer);
                            OSType format = CVPixelBufferGetPixelFormatType(imageBuffer);
                            writeLog(@"[step] Detalhes do buffer: %zux%zu, formato: %d", width, height, (int)format);
                        }
                    }
                } else if (shouldLog) {
                    writeLog(@"[step] Não foi possível obter um frame para exibição");
                }
            } else if (shouldLog) {
                writeLog(@"[step] g_frameProvider não está disponível para fornecer frames");
            }
        } else if (shouldLog) {
            writeLog(@"[step] g_previewLayer não está pronto para mais dados");
        }
    } else if (shouldLog) {
        writeLog(@"[step] g_previewLayer é NULL, não é possível exibir frames");
    }
}
%end

// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    writeLog(@"AVCaptureSession::startRunning - Câmera iniciando");
    g_cameraRunning = YES;
    %orig;
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    writeLog(@"AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    %orig;
}
%end

// Hook para interceptação do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    writeLog(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Delegate: %@, Queue: %@", sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // MODIFICAÇÃO: Em vez de retornar cedo se o delegate for nulo,
    // vamos ainda assim executar o método original para manter o comportamento padrão
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        writeLog(@"Delegate ou queue nulos, chamando método original");
        %orig;
        return;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooked = [NSMutableArray new];
    });
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    writeLog(@"Verificando classe do delegate: %@", className);
    
    // Verifica se esta classe já foi "hooked"
    if (![hooked containsObject:className]) {
        writeLog(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;
        
        // Verifica se o método existe na classe delegate antes de fazer o hook
        if ([sampleBufferDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            // Hook do método de recebimento de frames
            MSHookMessageEx(
                [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                    // Verificação CRUCIAL: Obter o status do burlador via Darwin Notifications
                    BOOL isSubstitutionActive = g_isSubstitutionActive;
                    
                    // Atualiza orientação para uso no step:
                    g_photoOrientation = [connection videoOrientation];
                    
                    // Log ocasional
                    static int callCount = 0;
                    if (++callCount % 300 == 0) {
                        writeLog(@"[captureOutput] Frame #%d, substituição: %@, orientação: %d",
                                callCount,
                                isSubstitutionActive ? @"ATIVA" : @"INATIVA",(int)g_photoOrientation);
                    }
                    
                    // Verificar se temos WebRTCFrameProvider e se burlador está ativo
                    if (isSubstitutionActive && g_frameProvider) {
                        // Adicionar log para debug
                        if (callCount % 300 == 0) {
                            writeLog(@"[captureOutput] Tentando obter frame do WebRTCFrameProvider");
                        }
                        
                        // Obtém um frame do WebRTC para substituir o buffer
                        CMSampleBufferRef newBuffer = [g_frameProvider getCurrentFrame:sampleBuffer forceReNew:NO];
                        
                        // Atualiza o preview usando o buffer obtido
                        if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                            [g_previewLayer flush];
                            [g_previewLayer enqueueSampleBuffer:newBuffer];
                            
                            // Log detalhado a cada 300 frames
                            if (callCount % 300 == 0) {
                                writeLog(@"[captureOutput] Preview atualizado com frame");
                            }
                        } else if (callCount % 300 == 0) {
                            writeLog(@"[captureOutput] Não foi possível atualizar preview - buffer: %@, layer: %@, ready: %d",
                                    newBuffer ? @"OK" : @"NULL",
                                    g_previewLayer ? @"OK" : @"NULL",
                                    g_previewLayer ? g_previewLayer.readyForMoreMediaData : -1);
                        }
                        
                        // Chama o método original com o buffer substituído
                        CMSampleBufferRef bufferToUse = newBuffer != nil ? newBuffer : sampleBuffer;
                        
                        // Log detalhado a cada 300 frames
                        if (callCount % 300 == 0) {
                            // Analisar o buffer para debug
                            if (newBuffer != nil) {
                                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(newBuffer);
                                if (imageBuffer) {
                                    size_t width = CVPixelBufferGetWidth(imageBuffer);
                                    size_t height = CVPixelBufferGetHeight(imageBuffer);
                                    OSType format = CVPixelBufferGetPixelFormatType(imageBuffer);
                                    writeLog(@"[captureOutput] Substituição de buffer: SIM (%zux%zu, formato: %d)",
                                          width, height, (int)format);
                                } else {
                                    writeLog(@"[captureOutput] Substituição de buffer: SIM (sem ImageBuffer)");
                                }
                            } else {
                                writeLog(@"[captureOutput] Substituição de buffer: NÃO (usando original)");
                            }
                        }
                        
                        return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, bufferToUse, connection);
                    }
                    
                    // Se não há substituição ativa, usa o buffer original
                    return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
                }), (IMP*)&original_method
            );
        } else {
            writeLog(@"[captureOutput] Delegate não implementa o método 'captureOutput:didOutputSampleBuffer:fromConnection:'");
        }
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
    g_isSubstitutionActive = NO;
    
    // Inicializar o provedor de frames
    g_frameProvider = [WebRTCFrameProvider sharedInstance];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Criar a janela flutuante
        g_floatingWindow = [[FloatingWindow alloc] init];
        
        // Estabelecer referências mútuas entre FloatingWindow e WebRTCFrameProvider
        g_frameProvider.floatingWindow = g_floatingWindow;
        
        [g_floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}
%end

// Modificação do FloatingWindow para trabalhar diretamente com o WebRTCFrameProvider
%hook FloatingWindow
- (void)toggleSubstitution:(UIButton *)sender {
    // Adicionar log detalhado para debug
    writeLog(@"[Hook] FloatingWindow::toggleSubstitution - Hook ativado");
    
    // Pega o estado atual do burlador (contrário do atual)
    BOOL newState = !self.isSubstitutionActive;
    writeLog(@"[Hook] Alterando estado do burlador para: %@", newState ? @"ATIVO" : @"INATIVO");
    
    // Atualiza a propriedade isSubstitutionActive
    self.isSubstitutionActive = newState;
    
    // Atualiza a interface de usuário
    if (newState) {
        [self.substitutionButton setTitle:@"Desativar Burlador" forState:UIControlStateNormal];
        self.substitutionButton.backgroundColor = [UIColor redColor];
        
        // Habilitar botão de preview
        self.toggleButton.enabled = YES;
        self.toggleButton.alpha = 1.0;
    } else {
        [self.substitutionButton setTitle:@"Ativar Burlador" forState:UIControlStateNormal];
        self.substitutionButton.backgroundColor = [UIColor systemBlueColor];
        
        // Desabilitar botão de preview e parar preview se estiver ativo
        if (self.isPreviewActive) {
            [self stopPreview];
        }
        self.toggleButton.enabled = NO;
        self.toggleButton.alpha = 0.5;
    }
    
    // Atualiza o ícone na versão minimizada
    [self updateMinimizedIconWithState];
    
    // Verificar se g_frameProvider está disponível
    if (g_frameProvider == nil) {
        writeLog(@"[Hook] ERRO: g_frameProvider é nil, tentando inicializar");
        g_frameProvider = [WebRTCFrameProvider sharedInstance];
    }
    
    // Chama o WebRTCFrameProvider para ativar/desativar o burlador
    if (g_frameProvider != nil) {
        writeLog(@"[Hook] Chamando setSubstitutionActive: %@", newState ? @"ATIVO" : @"INATIVO");
        [g_frameProvider setSubstitutionActive:newState];
    } else {
        writeLog(@"[Hook] ERRO CRÍTICO: g_frameProvider ainda é nil após tentativa de inicialização");
    }
}

// Substitui o método togglePreview para trabalhar com o WebRTCFrameProvider
- (void)togglePreview:(UIButton *)sender {
    if (self.isPreviewActive) {
        [self stopPreview];
    } else {
        [self startPreview];
    }
}

// Implementa o método didReceiveVideoTrack para funcionar com o WebRTCFrameProvider
%new
- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack {
    writeLog(@"[FloatingWindow] Faixa de vídeo recebida");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Configurar o videoView se existir
        if (self.videoView) {
            // Adicionar o renderer para o videoView se existir
            [videoTrack addRenderer:self.videoView];
        }
        
        // Marcar que estamos recebendo frames
        self.isReceivingFrames = YES;
        
        // Parar indicador de carregamento
        [self.loadingIndicator stopAnimating];
        
        // Atualizar ícone minimizado
        [self updateMinimizedIconWithState];
    });
}

%end

%ctor {
    writeLog(@"Constructor chamado - Inicializando tweak");
    
    // Chame a função de inicialização
    initializeGlobalVariables();
}

%dtor {
    writeLog(@"Destructor chamado - Limpando recursos");
    g_isSubstitutionActive = NO;
    if (g_floatingWindow) {
        [g_floatingWindow hide];
        g_floatingWindow = nil;
    }
    if (g_frameProvider) {
        [g_frameProvider stopWebRTC];
        g_frameProvider = nil;
    }
}
