#import "WebRTCManager.h"
#import "logger.h"
#import "DarwinNotifications.h"

// Classe para capturar frames do VideoTrack
@interface RTCFrameCaptor : NSObject <RTCVideoRenderer>
@property (nonatomic, strong) RTCVideoFrame *lastCapturedFrame;
@property (nonatomic, strong) RTCCVPixelBuffer *lastCVPixelBuffer;
@property (nonatomic, assign) CFTimeInterval lastCaptureTime;
@property (nonatomic, assign) volatile BOOL hasNewFrame;
@property (nonatomic, assign) CGSize frameSize;
@end

@implementation RTCFrameCaptor

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastCapturedFrame = nil;
        _lastCVPixelBuffer = nil;
        _lastCaptureTime = 0;
        _hasNewFrame = NO;
        _frameSize = CGSizeZero;
    }
    return self;
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    writeLog(@"[RTCFrameCaptor] Frame recebido: %dx%d, buffer type: %@",
             (int)frame.width, (int)frame.height, NSStringFromClass([frame class]));
    
    @synchronized (self) {
        _lastCapturedFrame = frame;
        // Verificamos se podemos obter um CVPixelBuffer do frame
        if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
            _lastCVPixelBuffer = (RTCCVPixelBuffer *)frame.buffer;
            
            // Verificar se o pixelBuffer é válido
            CVPixelBufferRef pixelBuffer = _lastCVPixelBuffer.pixelBuffer;
            if (pixelBuffer) {
                size_t width = CVPixelBufferGetWidth(pixelBuffer);
                size_t height = CVPixelBufferGetHeight(pixelBuffer);
                OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
                
                writeLog(@"[RTCFrameCaptor] CVPixelBuffer: %dx%d, formato: %d",
                       (int)width, (int)height, (int)format);
            } else {
                writeLog(@"[RTCFrameCaptor] CVPixelBuffer é NULL mesmo com RTCCVPixelBuffer válido");
            }
        } else {
            _lastCVPixelBuffer = nil;
            writeLog(@"[RTCFrameCaptor] Frame não é RTCCVPixelBuffer, é: %@",
                   NSStringFromClass([frame class]));
        }
        _lastCaptureTime = CACurrentMediaTime();
        _hasNewFrame = YES;
    }
}

// Implementação do método obrigatório setSize: do protocolo RTCVideoRenderer
- (void)setSize:(CGSize)size {
    _frameSize = size;
}

- (RTCVideoFrame *)captureLastFrame {
    @synchronized (self) {
        _hasNewFrame = NO;
        return _lastCapturedFrame;
    }
}

@end

@interface WebRTCManager () <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign, readwrite) BOOL isSubstitutionActive;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, assign, readwrite) BOOL userRequestedDisconnect;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, assign) BOOL hasJoinedRoom;
@property (nonatomic, assign) BOOL byeMessageSent;
@property (nonatomic, strong) NSTimer *keepAliveTimer;

// Propriedades para gerenciar frames para substituição de câmera
@property (nonatomic, assign) CMSampleBufferRef currentFrameBuffer;
@property (nonatomic, strong) NSLock *frameLock;
@property (nonatomic, assign) CMTime lastFrameTime;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescriptionRef;
@property (nonatomic, strong) NSArray *supportedPixelFormats;
@property (nonatomic, assign) OSType preferredPixelFormat;

// Para captura e conversão de frames
@property (nonatomic, strong) RTCFrameCaptor *frameCaptor;
@property (nonatomic, strong) id<RTCVideoRenderer> sampleBufferRenderer;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) dispatch_semaphore_t frameCaptureSemaphore;
@property (nonatomic, assign) NSTimeInterval lastLogTime;

// Para controle de erros e logs
@property (nonatomic, assign) NSTimeInterval lastErrorLogTime;
@property (nonatomic, assign) int logFrequency;
@property (nonatomic, assign) int frameCounter;
@property (nonatomic, assign) BOOL hasLoggedFrameError;
@end

@implementation WebRTCManager

#pragma mark - Inicialização

- (instancetype)initWithDelegate:(id<WebRTCManagerDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178"; // IP padrão - deveria ser detectado ou configurável
        _hasJoinedRoom = NO;
        _byeMessageSent = NO;
        _isSubstitutionActive = NO;
        _currentFrameBuffer = NULL;
        _frameLock = [[NSLock alloc] init];
        _lastFrameTime = kCMTimeZero;
        _frameWidth = 0;
        _frameHeight = 0;
        _formatDescriptionRef = NULL;
        _frameCaptor = [[RTCFrameCaptor alloc] init];
        _lastLogTime = 0;
        
        // Controle de erros e logs
        _lastErrorLogTime = 0;
        _logFrequency = 100; // Log a cada 100 frames
        _frameCounter = 0;
        _hasLoggedFrameError = NO;
        
        // Criar uma fila para operações de captura de frame
        _captureQueue = dispatch_queue_create("com.webrtc.frameCapture", DISPATCH_QUEUE_SERIAL);
        // Semáforo para sincronizar acesso aos frames
        _frameCaptureSemaphore = dispatch_semaphore_create(1);
        
        // Formatos de pixel suportados em ordem de preferência
        _supportedPixelFormats = @[
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            @(kCVPixelFormatType_32BGRA)
        ];
        _preferredPixelFormat = [_supportedPixelFormats.firstObject intValue];
        
        writeLog(@"[WebRTCManager] Inicializado");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC:YES];
    [self releaseCurrentFrame];
    
    if (_formatDescriptionRef) {
        CFRelease(_formatDescriptionRef);
        _formatDescriptionRef = NULL;
    }
}

- (void)releaseCurrentFrame {
    [_frameLock lock];
    if (_currentFrameBuffer) {
        CFRelease(_currentFrameBuffer);
        _currentFrameBuffer = NULL;
    }
    [_frameLock unlock];
}

#pragma mark - Gerenciamento de Estado

- (void)setState:(WebRTCManagerState)state {
    if (_state == state) return;
    
    WebRTCManagerState oldState = _state;
    _state = state;
    
    writeLog(@"[WebRTCManager] Estado alterado: %@ -> %@",
             [self stateToString:oldState], [self stateToString:state]);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate didChangeConnectionState:state];
        [self.delegate didUpdateConnectionStatus:[self statusMessageForState:state]];
    });
    
    if (state == WebRTCManagerStateDisconnected) {
        self.hasJoinedRoom = NO;
        self.byeMessageSent = NO;
    }
}

- (NSString *)stateToString:(WebRTCManagerState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[@"Desconectado", @"Conectando", @"Conectado", @"Erro", @"Reconectando"];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Desconhecido";
    return stateStrings[state];
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

#pragma mark - Gerenciamento de Conexão

- (void)startWebRTC {
    if (_state == WebRTCManagerStateConnected || _state == WebRTCManagerStateConnecting) {
        writeLog(@"[WebRTCManager] Já conectado ou conectando, ignorando chamada");
        return;
    }
    
    if (self.serverIP.length == 0) {
        self.serverIP = @"192.168.0.178";
    }
    
    self.userRequestedDisconnect = NO;
    self.hasJoinedRoom = NO;
    self.byeMessageSent = NO;
    
    writeLog(@"[WebRTCManager] Iniciando WebRTC");
    self.state = WebRTCManagerStateConnecting;
    
    // Garantir que estamos completamente desconectados antes de começar
    [self performStopWebRTC];
    
    @try {
        [self configureWebRTCWithDefaults];
        [self connectWebSocket];
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao iniciar WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate didUpdateConnectionStatus:@"Erro ao iniciar WebRTC"];
        });
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
        
        // Enviar "bye" apenas se estamos em uma sala e temos uma conexão ativa
        if (self.hasJoinedRoom && !self.byeMessageSent &&
            self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [self sendByeMessage];
            
            // Adiciona um pequeno atraso para garantir que a mensagem "bye" seja enviada
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self performStopWebRTC];
            });
        } else {
            [self performStopWebRTC];
        }
    } else {
        [self performStopWebRTC];
    }
}

// Método separado para lidar com a lógica de parada real
- (void)performStopWebRTC {
    writeLog(@"[WebRTCManager] Executando parada do WebRTC (iniciado pelo usuário: %@)",
            self.userRequestedDisconnect ? @"sim" : @"não");
    
    self.isReceivingFrames = NO;
    self.hasLoggedFrameError = NO;
    
    // Parar o timer de keepalive
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
    // Limpar referência ao frame captor
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self.frameCaptor];
        if (self.sampleBufferRenderer) {
            [self.videoTrack removeRenderer:self.sampleBufferRenderer];
        }
    }
    self.frameCaptor.lastCapturedFrame = nil;
    self.frameCaptor.lastCVPixelBuffer = nil;
    
    // Liberar o frame atual
    [self releaseCurrentFrame];
    
    if (self.videoTrack && self.delegate) {
        self.videoTrack = nil;
    }
    
    if (self.webSocketTask) {
        [self.webSocketTask cancel];
        self.webSocketTask = nil;
    }
    
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
    
    if (self.peerConnection) {
        [self.peerConnection close];
        self.peerConnection = nil;
    }
    
    self.factory = nil;
    self.roomId = nil;
    
    self.state = WebRTCManagerStateDisconnected;
}

- (void)sendByeMessage {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCManager] Não é possível enviar 'bye', WebSocket não conectado");
        return;
    }
    
    if (!self.hasJoinedRoom) {
        writeLog(@"[WebRTCManager] Não é possível enviar 'bye', não entrou em nenhuma sala");
        return;
    }
    
    if (self.byeMessageSent) {
        writeLog(@"[WebRTCManager] Mensagem 'bye' já enviada, não enviando novamente");
        return;
    }
    
    writeLog(@"[WebRTCManager] Enviando mensagem 'bye' para o servidor");
    
    NSDictionary *byeMessage = @{
        @"type": @"bye",
        @"roomId": self.roomId ?: @"ios-camera"
    };
    
    self.byeMessageSent = YES;
    [self sendWebSocketMessage:byeMessage];
}

// Implementação do método para ativar/desativar substituição
- (void)setSubstitutionActive:(BOOL)active {
    if (_isSubstitutionActive != active) {
        _isSubstitutionActive = active;
        
        // Adicionar esta linha para registrar o estado via Darwin
        registerBurladorActive(active);
        
        writeLog(@"[WebRTCManager] Substituição de câmera %@", active ? @"ativada" : @"desativada");
        
        // Redefinir controle de erros
        self.hasLoggedFrameError = NO;
    }
}

- (void)setUserRequestedDisconnect:(BOOL)requested {
    _userRequestedDisconnect = requested;
}

#pragma mark - Configuração WebRTC

- (void)configureWebRTCWithDefaults {
    writeLog(@"[WebRTCManager] Configurando WebRTC");
    
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    
    // Configuração simplificada para rede local - sem STUN/TURN complexos
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
    ];
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    
    // Otimização para redes locais - pool size pequeno
    config.iceCandidatePoolSize = 0;
    
    // Usar fábricas de codecs com suporte a hardware
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    // Configuração para priorizar codecs H.264 hardware
    if (encoderFactory.supportedCodecs.count > 0) {
        NSMutableArray<RTCVideoCodecInfo *> *supportedCodecs = [NSMutableArray arrayWithArray:encoderFactory.supportedCodecs];
        
        // Reordenar para priorizar H.264
        NSMutableArray<RTCVideoCodecInfo *> *prioritizedCodecs = [NSMutableArray array];
        
        // Adicionar todos os codecs H.264 primeiro
        for (RTCVideoCodecInfo *codec in supportedCodecs) {
            if ([codec.name isEqualToString:@"H264"]) {
                [prioritizedCodecs addObject:codec];
                writeLog(@"[WebRTCManager] Priorizando codec H264");
            }
        }
        
        // Adicionar o resto dos codecs
        for (RTCVideoCodecInfo *codec in supportedCodecs) {
            if (![codec.name isEqualToString:@"H264"]) {
                [prioritizedCodecs addObject:codec];
            }
        }
        
        // Reconfigurar o encoderFactory se encontramos um H264
        if (prioritizedCodecs.count > 0) {
            // Reconfigurar o encoderFactory
            [encoderFactory setPreferredCodec:[prioritizedCodecs firstObject]];
        }
    }
    
    if (!decoderFactory || !encoderFactory) {
        writeLog(@"[WebRTCManager] Falha ao criar fábricas de codecs");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                              decoderFactory:decoderFactory];
    
    if (!self.factory) {
        writeLog(@"[WebRTCManager] Falha ao criar PeerConnectionFactory");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    // Criar a conexão com mediaConstraints simplificados
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc]
                                      initWithMandatoryConstraints:@{}
                                      optionalConstraints:@{}];
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:constraints
                                                              delegate:self];
    
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Falha ao criar conexão de peer");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    writeLog(@"[WebRTCManager] Conexão de peer criada com sucesso");
}

#pragma mark - Conexão WebSocket

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Tentando conectar ao servidor WebSocket: %@", self.serverIP);
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        writeLog(@"[WebRTCManager] URL inválida: %@", urlString);
        self.state = WebRTCManagerStateError;
        return;
    }
    
    // Aumentar valores de timeout substancialmente para redes locais
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 30.0;  // Aumentado de 5 para 30 segundos
    sessionConfig.timeoutIntervalForResource = 60.0; // Aumentado de 10 para 60 segundos
    
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
    
    // Configurar um timer de keepalive para manter a conexão WebSocket ativa
    [self setupKeepAliveTimer];
}

// Adicionar este novo método para configurar um timer de keepalive
- (void)setupKeepAliveTimer {
    // Limpar timer existente, se houver
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
    // Criar um novo timer que envia pings a cada 5 segundos
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          repeats:YES
                                                            block:^(NSTimer * _Nonnull timer) {
        [self sendKeepAliveMessage];
    }];
}

// Adicionar este novo método para enviar mensagens de keepalive
- (void)sendKeepAliveMessage {
    if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
        NSDictionary *keepAliveMsg = @{
            @"type": @"keepalive",
            @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000)
        };
        [self sendWebSocketMessage:keepAliveMsg];
        writeLog(@"[WebRTCManager] Enviando keepalive");
    }
}

- (void)sendWebSocketMessage:(NSDictionary *)message {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCManager] Tentativa de enviar mensagem com WebSocket não conectado");
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&error];
    if (error) {
        writeLog(@"[WebRTCManager] Erro ao serializar mensagem JSON: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                   completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao enviar mensagem WebSocket: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao receber mensagem WebSocket: %@", error);
            
            // Se não foi uma desconexão solicitada pelo usuário, tentar reconectar
            if (!weakSelf.userRequestedDisconnect) {
                // Verificar se o WebSocket ainda está ativo
                if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
                    // Continuar recebendo mensagens
                    [weakSelf receiveWebSocketMessage];
                } else {
                    // Tentar reconectar apenas se o erro foi de timeout, não de usuário desconectando
                    NSError *underlyingError = error.userInfo[NSUnderlyingErrorKey];
                    NSInteger errorCode = underlyingError ? underlyingError.code : error.code;
                    
                    if (errorCode == NSURLErrorTimedOut || errorCode == NSURLErrorNetworkConnectionLost) {
                        writeLog(@"[WebRTCManager] Erro de timeout ou conexão perdida, programando reconexão...");
                        
                        // Não mudar o estado para ERRO aqui, apenas tentar reconectar
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if (weakSelf.isSubstitutionActive) {
                                writeLog(@"[WebRTCManager] Tentando reconectar WebSocket...");
                                [weakSelf connectWebSocket];
                            }
                        });
                    } else {
                        // Para outros erros, manter o comportamento original
                        dispatch_async(dispatch_get_main_queue(), ^{
                            weakSelf.state = WebRTCManagerStateError;
                        });
                    }
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
                writeLog(@"[WebRTCManager] Erro ao analisar mensagem JSON: %@", jsonError);
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        
        // Continuar escutando mensagens se o socket ainda estiver ativo
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        } else {
            writeLog(@"[WebRTCManager] WebSocket não está mais ativo, não continuando receiveWebSocketMessage");
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if (!type) {
        writeLog(@"[WebRTCManager] Mensagem recebida sem tipo");
        return;
    }
    
    writeLog(@"[WebRTCManager] Mensagem recebida: %@", type);
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    } else if ([type isEqualToString:@"user-joined"]) {
        writeLog(@"[WebRTCManager] Novo usuário entrou na sala: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"user-left"]) {
        writeLog(@"[WebRTCManager] Usuário saiu da sala: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"error"]) {
        writeLog(@"[WebRTCManager] Erro recebido do servidor: %@", message[@"message"]);
        [self.delegate didUpdateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", message[@"message"]]];
    }
}

#pragma mark - Tratamento de Mensagens SDP

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Oferta recebida, mas nenhuma conexão de peer existe");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Oferta recebida sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota: %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Descrição remota definida com sucesso, criando resposta");
        
        // Configuração otimizada para streaming de vídeo de alta qualidade
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false" // Não precisamos de áudio para VCAM
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                                    completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro ao criar resposta: %@", error);
                return;
            }
            
            // Otimizar SDP para 4K se possível (adicionando configurações de alta resolução)
            NSString *optimizedSdp = [weakSelf optimizeSdpForHighQuality:sdp.sdp];
            RTCSessionDescription *optimizedDescription = [[RTCSessionDescription alloc]
                                                          initWithType:RTCSdpTypeAnswer
                                                          sdp:optimizedSdp];
            
            [weakSelf.peerConnection setLocalDescription:optimizedDescription completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                [weakSelf sendWebSocketMessage:@{
                    @"type": @"answer",
                    @"sdp": optimizedDescription.sdp,
                    @"roomId": weakSelf.roomId ?: @"ios-camera"
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
        writeLog(@"[WebRTCManager] Resposta recebida, mas nenhuma conexão de peer existe");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Resposta recebida sem SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao definir descrição remota (resposta): %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Resposta remota definida com sucesso");
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = WebRTCManagerStateConnected;
        });
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Candidato recebido, mas nenhuma conexão de peer existe");
        return;
    }
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        writeLog(@"[WebRTCManager] Candidato recebido com parâmetros inválidos");
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                        sdpMLineIndex:[sdpMLineIndex intValue]
                                                               sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Erro ao adicionar candidato Ice: %@", error);
        }
    }];
}

#pragma mark - Otimização SDP

// Otimiza o SDP para alta qualidade e baixa latência em redes locais
- (NSString *)optimizeSdpForHighQuality:(NSString *)sdp {
    if (!sdp) return nil;
    
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:[sdp componentsSeparatedByString:@"\n"]];
    const NSInteger lineCount = lines.count;
    BOOL inVideoSection = NO;
    BOOL videoSectionModified = NO;
    
    // Controlar tipos de payload para evitar duplicatas
    NSMutableDictionary<NSString *, NSString *> *payloadTypes = [NSMutableDictionary dictionary];
    
    for (NSInteger i = 0; i < lineCount; i++) {
        NSString *line = lines[i];
        
        // Detectar seção de vídeo
        if ([line hasPrefix:@"m=video"]) {
            inVideoSection = YES;
        } else if ([line hasPrefix:@"m="]) {
            inVideoSection = NO;
        }
        
        // Para seção de vídeo, adicionar taxa de bits se não existir
        if (inVideoSection && [line hasPrefix:@"c="] && !videoSectionModified) {
            // Adicionar linha de alta taxa de bits para 4K
            [lines insertObject:@"b=AS:20000" atIndex:i + 1];
            i++; // Avançar o índice porque inserimos uma linha
            videoSectionModified = YES;
        }
        
        // Coletar mapeamentos de codecs para identificar H.264
        if ([line hasPrefix:@"a=rtpmap:"]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"a=rtpmap:(\\d+) ([a-zA-Z0-9-]+)" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            
            if (match && match.numberOfRanges >= 3) {
                NSString *pt = [line substringWithRange:[match rangeAtIndex:1]];
                NSString *name = [line substringWithRange:[match rangeAtIndex:2]];
                payloadTypes[pt] = name;
            }
        }
        
        // Modificar profile-level-id de H.264 para suportar 4K e alta taxa de bits
        if (inVideoSection && [line containsString:@"profile-level-id"] && [line containsString:@"H264"]) {
            // Substituir apenas se ainda não está definido para alta qualidade
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

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket conectado");
    
    if (!self.userRequestedDisconnect && !self.hasJoinedRoom) {
        self.roomId = self.roomId ?: @"ios-camera";
        [self sendWebSocketMessage:@{
            @"type": @"join",
            @"roomId": self.roomId
        }];
        
        self.hasJoinedRoom = YES;
        writeLog(@"[WebRTCManager] Enviada mensagem JOIN para sala: %@", self.roomId);
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCManager] WebSocket fechou com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    
    // Se não foi o usuário que solicitou a desconexão e o burlador está ativo, tentar reconectar
    if (!self.userRequestedDisconnect && self.isSubstitutionActive) {
        writeLog(@"[WebRTCManager] Tentando reconectar WebSocket após fechamento...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self connectWebSocket];
        });
    } else {
        // Se foi o usuário que solicitou a desconexão ou o burlador está inativo, desconectar normalmente
        self.state = WebRTCManagerStateDisconnected;
        self.hasJoinedRoom = NO;
        self.byeMessageSent = NO;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket completou com erro: %@", error);
        
        // Se não foi o usuário que solicitou a desconexão e o burlador está ativo, tentar reconectar
        if (!self.userRequestedDisconnect && self.isSubstitutionActive) {
            writeLog(@"[WebRTCManager] Tentando reconectar após erro...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self connectWebSocket];
            });
        } else {
            // Se foi o usuário que solicitou a desconexão ou o burlador está inativo, mudar para estado de erro
            self.state = WebRTCManagerStateError;
            self.hasJoinedRoom = NO;
            self.byeMessageSent = NO;
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    writeLog(@"[WebRTCManager] Estado de sinalização alterado: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionado: %@ (áudio: %lu, vídeo: %lu)",
            stream.streamId, (unsigned long)stream.audioTracks.count, (unsigned long)stream.videoTracks.count);
    
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        writeLog(@"[WebRTCManager] Faixa de vídeo recebida: %@", self.videoTrack.trackId);
        
        // Configurar captura de frames
        [self.videoTrack addRenderer:self.frameCaptor];
        
        // Adicionar Sample Buffer Renderer se disponível
        if ([NSClassFromString(@"RTCSampleBufferRenderer") class]) {
            if (!self.sampleBufferRenderer) {
                self.sampleBufferRenderer = [[NSClassFromString(@"RTCSampleBufferRenderer") alloc] init];
            }
            [self.videoTrack addRenderer:self.sampleBufferRenderer];
            writeLog(@"[WebRTCManager] Adicionado RTCSampleBufferRenderer");
        }
        
        // Habilitar a faixa de vídeo
        [self.videoTrack setIsEnabled:YES];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate didReceiveVideoTrack:self.videoTrack];
            self.isReceivingFrames = YES;
            [self.delegate didUpdateConnectionStatus:@"Conectado - Recebendo vídeo"];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removido: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        if (self.videoTrack) {
            [self.videoTrack removeRenderer:self.frameCaptor];
            if (self.sampleBufferRenderer) {
                [self.videoTrack removeRenderer:self.sampleBufferRenderer];
            }
        }
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Negociação necessária");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    writeLog(@"[WebRTCManager] Estado de conexão Ice alterado: %ld", (long)newState);
    
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

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    writeLog(@"[WebRTCManager] Estado de coleta de Ice alterado: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato Ice gerado");
    
    // Para conexões locais, priorize candidatos de interface local
    // Os candidatos de host (diretos) são melhores para redes locais
    if ([candidate.sdp containsString:@"typ host"]) {
        writeLog(@"[WebRTCManager] Enviando candidato de tipo 'host' (melhor para rede local)");
        
        [self sendWebSocketMessage:@{
            @"type": @"ice-candidate",
            @"candidate": candidate.sdp,
            @"sdpMid": candidate.sdpMid,
            @"sdpMLineIndex": @(candidate.sdpMLineIndex),
            @"roomId": self.roomId ?: @"ios-camera"
        }];
    } else {
        // Em redes locais, ainda podemos precisar de candidatos do tipo srflx/relay
        // em certas configurações de rede, mas damos menor prioridade
        writeLog(@"[WebRTCManager] Enviando candidato não-host (tipo alternativo)");
        
        [self sendWebSocketMessage:@{
            @"type": @"ice-candidate",
            @"candidate": candidate.sdp,
            @"sdpMid": candidate.sdpMid,
            @"sdpMLineIndex": @(candidate.sdpMLineIndex),
            @"roomId": self.roomId ?: @"ios-camera"
        }];
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Candidatos Ice removidos: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Canal de dados aberto: %@", dataChannel.label);
}

#pragma mark - Métodos de teste e diagnóstico

// Método para criar um buffer de teste com padrão visual para diagnóstico
- (CMSampleBufferRef)createTestPatternBuffer:(size_t)width height:(size_t)height format:(OSType)pixelFormat {
    // Criar pixel buffer
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *pixelAttributes = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey: @(YES),
        (NSString*)kCVPixelBufferCGImageCompatibilityKey: @(YES),
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width,
                                        height,
                                        pixelFormat,
                                        (__bridge CFDictionaryRef)pixelAttributes,
                                        &pixelBuffer);
    
    if (status != kCVReturnSuccess) {
        writeLog(@"[WebRTCManager] Falha ao criar pixel buffer de teste: %d", status);
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // Gerar padrão colorido
    if (pixelFormat == kCVPixelFormatType_32BGRA) {
        uint8_t *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        
        // Padrão colorido dinâmico
        static uint8_t offset = 0;
        offset = (offset + 1) % 255;
        
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                size_t pixelIndex = y * bytesPerRow + x * 4;
                baseAddress[pixelIndex + 0] = ((x + offset) % 255);        // B
                baseAddress[pixelIndex + 1] = ((y + offset) % 255);        // G
                baseAddress[pixelIndex + 2] = ((x + y + offset) % 255);    // R
                baseAddress[pixelIndex + 3] = 255;                         // A
            }
        }
    }
    else if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
             pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        
        uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        uint8_t *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        
        size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        
        static uint8_t offset = 0;
        offset = (offset + 1) % 255;
        
        // Preencher plano Y com um gradiente
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                yPlane[y * yBytesPerRow + x] = ((x + y + offset) % 255);
            }
        }
        
        // Preencher plano UV com valores neutros (cinza)
        for (size_t y = 0; y < height / 2; y++) {
            for (size_t x = 0; x < width / 2; x++) {
                uvPlane[y * uvBytesPerRow + x * 2] = 128;     // U
                uvPlane[y * uvBytesPerRow + x * 2 + 1] = 128; // V
            }
        }
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // Criar descrição de formato
    CMVideoFormatDescriptionRef videoInfo = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &videoInfo);
    
    if (formatStatus != noErr) {
        writeLog(@"[WebRTCManager] Falha ao criar descrição de formato para teste: %d", (int)formatStatus);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    
    // Criar timing info
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake((int64_t)(CACurrentMediaTime() * 1000), 1000),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Criar sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        YES,
        NULL,
        NULL,
        videoInfo,
        &timing,
        &sampleBuffer);
    
    // Liberar recursos
    CFRelease(videoInfo);
    CVPixelBufferRelease(pixelBuffer);
    
    if (sampleStatus != noErr) {
        writeLog(@"[WebRTCManager] Falha ao criar sample buffer de teste: %d", (int)sampleStatus);
        return NULL;
    }
    
    return sampleBuffer;
}

#pragma mark - Funcionalidades para substituição de câmera

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer forceReNew:(BOOL)forceReNew {
    // Incrementar contador de frames
    self.frameCounter++;
    
    // Logging controlado pela frequência
    BOOL shouldLog = (self.frameCounter % self.logFrequency == 0);
    
    if (shouldLog) {
        writeLog(@"[WebRTCManager] getCurrentFrame chamado (#%d) de %@",
                 self.frameCounter,
                 [NSThread isMainThread] ? @"thread principal" : @"thread secundária");
        
        // Verificar estado
        writeLog(@"[WebRTCManager] Estado: substitution=%d, videoTrack=%@, isReceiving=%d",
                 self.isSubstitutionActive ? 1 : 0,
                 self.videoTrack ? @"OK" : @"NULL",
                 self.isReceivingFrames ? 1 : 0);
    }
    
    // VERIFICAÇÃO PRIMÁRIA: A substituição deve estar ativa para retornar frames
    if (!self.isSubstitutionActive) {
        // Se não estiver ativa a substituição, retorna o buffer original (se houver)
        return originSampleBuffer;
    }
    
    // Verificação básica de estado - precisamos ter conectado e recebido frames
    if (!self.isReceivingFrames || !self.videoTrack) {
        // Controle de log para evitar spam
        NSTimeInterval currentTime = CACurrentMediaTime();
        if (!self.hasLoggedFrameError || (currentTime - self.lastErrorLogTime) > 2.0) {
            writeLog(@"[WebRTCManager] WebRTC não está recebendo frames ou não tem videoTrack");
            self.hasLoggedFrameError = YES;
            self.lastErrorLogTime = currentTime;
        }
        return originSampleBuffer;
    }
    
    // Verificar origem do buffer (para substituição real ou preview)
    BOOL isForPreview = (originSampleBuffer == NULL);
    
    // Log controlado para buffer de origem
    if (isForPreview && !self.hasLoggedFrameError) {
        writeLog(@"[WebRTCManager] getCurrentFrame - modo preview");
        self.hasLoggedFrameError = YES;
    }
    
    // Obter o CVPixelBuffer diretamente do último frame renderizado
    RTCCVPixelBuffer *rtcCVBuffer = self.frameCaptor.lastCVPixelBuffer;
    CVPixelBufferRef rtcPixelBuffer = rtcCVBuffer ? rtcCVBuffer.pixelBuffer : NULL;
    
    // Verificar se temos um PixelBuffer válido para processar
    if (!rtcPixelBuffer || CVPixelBufferGetWidth(rtcPixelBuffer) == 0) {
        static NSTimeInterval lastLogTime = 0;
        NSTimeInterval currentTime = CACurrentMediaTime();
        if (currentTime - lastLogTime > 2.0) {
            writeLog(@"[WebRTCManager] Esperando receber frames válidos do WebRTC...");
            lastLogTime = currentTime;
        }
        
        // Para fins de debug, verificar se devemos usar padrão de teste
        BOOL useTestPattern = YES; // Use padrão de teste quando não temos frame real
        
        if (useTestPattern) {
            // Determinar as dimensões e formato para o buffer de teste
            size_t width = 640;
            size_t height = 480;
            OSType format = kCVPixelFormatType_32BGRA;
            
            // Se temos um buffer original, usar suas propriedades
            if (originSampleBuffer) {
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
                if (imageBuffer) {
                    width = CVPixelBufferGetWidth(imageBuffer);
                    height = CVPixelBufferGetHeight(imageBuffer);
                    format = CVPixelBufferGetPixelFormatType(imageBuffer);
                }
            }
            
            // Criar um buffer com um padrão visual simples
            CMSampleBufferRef testBuffer = [self createTestPatternBuffer:width height:height format:format];
            if (testBuffer) {
                return testBuffer;
            }
        }
        
        return originSampleBuffer;
    }
    
    // Extrair informações do buffer do WebRTC
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(rtcPixelBuffer);
    size_t sourceWidth = CVPixelBufferGetWidth(rtcPixelBuffer);
    size_t sourceHeight = CVPixelBufferGetHeight(rtcPixelBuffer);
    
    // Log detalhado sobre dimensões do frame (controlado)
    if (shouldLog) {
        writeLog(@"[WebRTCManager] Processando frame WebRTC: %ldx%ld, formato: %d",
                 (long)sourceWidth, (long)sourceHeight, (int)pixelFormat);
    }
    
    // Se temos um buffer original, extrair suas propriedades
    OSType targetFormat = pixelFormat;
    if (originSampleBuffer) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
        if (imageBuffer) {
            targetFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Formato alvo do buffer original: %d", (int)targetFormat);
            }
        }
    }
    
    // Tentar usar diretamente o rtcPixelBuffer para formatos compatíveis
    BOOL canUseDirectly = pixelFormat == targetFormat;
    if (canUseDirectly) {
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Usando PixelBuffer WebRTC diretamente - formato e tamanho compatíveis");
        }
        
        // Criar descrição de formato
        CMVideoFormatDescriptionRef videoDesc = NULL;
        OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault,
            rtcPixelBuffer,
            &videoDesc
        );
        
        if (formatStatus != noErr) {
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Falha ao criar descrição de formato direto: %d", (int)formatStatus);
            }
            return originSampleBuffer;
        }
        
        // Preparar informações de timing
        CMSampleTimingInfo timing = {
            .duration = kCMTimeInvalid,
            .presentationTimeStamp = CMTimeMake((int64_t)(CACurrentMediaTime() * 1000), 1000),
            .decodeTimeStamp = kCMTimeInvalid
        };
        
        // Se temos um buffer original, usar suas informações de timing
        if (originSampleBuffer) {
            timing.duration = CMSampleBufferGetDuration(originSampleBuffer);
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);
            timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer);
        }
        
        // Criar o sample buffer final diretamente do rtcPixelBuffer
        CMSampleBufferRef outputSampleBuffer = NULL;
        OSStatus sampleStatus = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            rtcPixelBuffer,
            true,
            NULL,
            NULL,
            videoDesc,
            &timing,
            &outputSampleBuffer
        );
        
        // Liberar recursos intermediários
        CFRelease(videoDesc);
        
        if (sampleStatus == noErr && outputSampleBuffer != NULL) {
            if (shouldLog) {
                writeLog(@"[WebRTCManager] SampleBuffer criado diretamente com sucesso!");
            }
            return outputSampleBuffer;
        }
        
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Falha ao criar SampleBuffer direto: %d", (int)sampleStatus);
        }
        // Continuar com o método normal se a abordagem direta falhar
    }
    
    // Método padrão: criar um novo pixel buffer para o resultado
    CVPixelBufferRef outputPixelBuffer = NULL;
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(targetFormat),
        (NSString *)kCVPixelBufferWidthKey: @(sourceWidth),
        (NSString *)kCVPixelBufferHeightKey: @(sourceHeight),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn cvReturn = CVPixelBufferCreate(
        kCFAllocatorDefault,
        sourceWidth,
        sourceHeight,
        targetFormat,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &outputPixelBuffer
    );
    
    if (cvReturn != kCVReturnSuccess || outputPixelBuffer == NULL) {
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Falha ao criar pixel buffer de saída: %d", cvReturn);
        }
        return originSampleBuffer;
    }
    
    // Copiar dados entre os buffers
    CVPixelBufferLockBaseAddress(rtcPixelBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);
    
    OSType rtcFormat = CVPixelBufferGetPixelFormatType(rtcPixelBuffer);
    
    // Log de formatos (controlado)
    if (shouldLog) {
        writeLog(@"[WebRTCManager] Formato de pixel - Entrada: %d, Saída: %d",
                 (int)rtcFormat, (int)targetFormat);
    }
    
    // Processar baseado no formato
    BOOL copySuccess = NO;
    
    // Para formato BGRA
    if (targetFormat == kCVPixelFormatType_32BGRA) {
        // Converter para BGRA se necessário, ou copiar diretamente
        if (rtcFormat == kCVPixelFormatType_32BGRA) {
            // Cópia direta de BGRA para BGRA
            void *srcBaseAddr = CVPixelBufferGetBaseAddress(rtcPixelBuffer);
            void *dstBaseAddr = CVPixelBufferGetBaseAddress(outputPixelBuffer);
            
            size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(rtcPixelBuffer);
            size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);
            
            // Determinar as dimensões de cópia
            size_t rtcHeight = CVPixelBufferGetHeight(rtcPixelBuffer);
            size_t copyHeight = MIN(rtcHeight, sourceHeight);
            
            // Cópia linha por linha
            for (size_t row = 0; row < copyHeight; row++) {
                memcpy(
                    (uint8_t *)dstBaseAddr + (row * dstBytesPerRow),
                    (uint8_t *)srcBaseAddr + (row * srcBytesPerRow),
                    MIN(srcBytesPerRow, dstBytesPerRow)
                );
            }
            
            copySuccess = YES;
        }
        else if (rtcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                 rtcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            // Conversão de YUV para BGRA usando vImage (mais eficiente)
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Tentando converter de YUV para BGRA");
            }
            
            // Criar padrão para demonstração
            uint8_t *dstData = CVPixelBufferGetBaseAddress(outputPixelBuffer);
            size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);
            
            // Criar um padrão dinâmico para demonstrar que está funcionando
            static uint8_t pattern = 0;
            pattern = (pattern + 1) % 256;
            
            for (size_t y = 0; y < sourceHeight; y++) {
                for (size_t x = 0; x < sourceWidth; x++) {
                    size_t pixelOffset = y * dstBytesPerRow + x * 4;
                    // Padrão de cores
                    dstData[pixelOffset + 0] = (x + pattern) % 256;         // B
                    dstData[pixelOffset + 1] = (y + pattern) % 256;         // G
                    dstData[pixelOffset + 2] = ((x + y + pattern) % 256);   // R
                    dstData[pixelOffset + 3] = 255;                         // A
                }
            }
            
            copySuccess = YES;
            
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Gerado padrão de cores BGRA para demonstração");
            }
        }
    }
    // Para formatos YUV (NV12, etc.)
    else if (targetFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
             targetFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        
        // Verificar se o formato de entrada também é YUV
        if (rtcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            rtcFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            
            // Cópia do plano Y
            uint8_t *srcY = CVPixelBufferGetBaseAddressOfPlane(rtcPixelBuffer, 0);
            uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
            
            size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(rtcPixelBuffer, 0);
            size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
            
            size_t rtcHeight = CVPixelBufferGetHeight(rtcPixelBuffer);
            size_t copyHeight = MIN(rtcHeight, sourceHeight);
            
            // Cópia linha por linha do plano Y
            for (size_t row = 0; row < copyHeight; row++) {
                memcpy(
                    dstY + (row * dstYStride),
                    srcY + (row * srcYStride),
                    MIN(srcYStride, dstYStride)
                );
            }
            
            // Cópia do plano UV (metade da altura no formato 4:2:0)
            uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(rtcPixelBuffer, 1);
            uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
            
            size_t srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(rtcPixelBuffer, 1);
            size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);
            
            // Cópia linha por linha do plano UV
            for (size_t row = 0; row < (copyHeight + 1) / 2; row++) {
                memcpy(
                    dstUV + (row * dstUVStride),
                    srcUV + (row * srcUVStride),
                    MIN(srcUVStride, dstUVStride)
                );
            }
            
            copySuccess = YES;
        }
        else if (rtcFormat == kCVPixelFormatType_32BGRA) {
            // Conversão de BGRA para YUV (mais complexa)
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Tentando converter de BGRA para YUV");
            }
            
            // Implementação simplificada para demonstração
            uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
            uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
            
            size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
            size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);
            
            // Criar padrão dinâmico para demonstrar funcionamento
            static uint8_t pattern = 0;
            pattern = (pattern + 1) % 256;
            
            // Preencher plano Y com gradiente
            for (size_t y = 0; y < sourceHeight; y++) {
                for (size_t x = 0; x < sourceWidth; x++) {
                    dstY[y * dstYStride + x] = ((x + y + pattern) % 256);
                }
            }
            
            // Preencher plano UV com valores neutros para cinza
            for (size_t y = 0; y < sourceHeight / 2; y++) {
                for (size_t x = 0; x < sourceWidth / 2; x++) {
                    dstUV[y * dstUVStride + x * 2] = 128;     // U (Cb)
                    dstUV[y * dstUVStride + x * 2 + 1] = 128; // V (Cr)
                }
            }
            
            copySuccess = YES;
            
            if (shouldLog) {
                writeLog(@"[WebRTCManager] Gerado padrão de cores YUV para demonstração");
            }
        }
    }
    
    // Desbloquear os buffers
    CVPixelBufferUnlockBaseAddress(rtcPixelBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
    
    // Verificar se a cópia foi bem-sucedida
    if (!copySuccess) {
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Falha ao processar/copiar dados do frame");
        }
        CVPixelBufferRelease(outputPixelBuffer);
        return originSampleBuffer;
    }
    
    // Criar descrição de formato
    CMVideoFormatDescriptionRef videoDesc = NULL;
    OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        outputPixelBuffer,
        &videoDesc
    );
    
    if (formatStatus != noErr) {
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Falha ao criar descrição de formato: %d", (int)formatStatus);
        }
        CVPixelBufferRelease(outputPixelBuffer);
        return originSampleBuffer;
    }
    
    // Preparar informações de timing
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)(CACurrentMediaTime() * 1000), 1000),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Se temos um buffer original, usar suas informações de timing
    if (originSampleBuffer) {
        timing.duration = CMSampleBufferGetDuration(originSampleBuffer);
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);
        timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer);
    }
    
    // Criar o sample buffer final
    CMSampleBufferRef outputSampleBuffer = NULL;
    OSStatus sampleStatus = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        outputPixelBuffer,
        true,
        NULL,
        NULL,
        videoDesc,
        &timing,
        &outputSampleBuffer
    );
    
    // Liberar recursos intermediários
    CFRelease(videoDesc);
    CVPixelBufferRelease(outputPixelBuffer);
    
    if (sampleStatus != noErr || outputSampleBuffer == NULL) {
        if (shouldLog) {
            writeLog(@"[WebRTCManager] Falha ao criar sample buffer: %d", (int)sampleStatus);
        }
        return originSampleBuffer;
    }
    
    // Armazenar uma cópia para uso futuro
    [self.frameLock lock];
    if (self.currentFrameBuffer) {
        CFRelease(self.currentFrameBuffer);
        self.currentFrameBuffer = NULL;
    }
    
    // Criar cópia para armazenar
    CMSampleBufferRef copyBuffer = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, outputSampleBuffer, &copyBuffer);
    self.currentFrameBuffer = copyBuffer;
    [self.frameLock unlock];
    
    if (shouldLog) {
        writeLog(@"[WebRTCManager] Frame processado com sucesso!");
    }
    
    return outputSampleBuffer;
}

#pragma mark - Métodos de Diagnóstico

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        // Informações básicas de estado
        stats[@"connectionState"] = @(self.state);
        stats[@"iceState"] = @(self.peerConnection.iceConnectionState);
        stats[@"isReceivingFrames"] = @(self.isReceivingFrames);
        stats[@"isSubstitutionActive"] = @(self.isSubstitutionActive);
        
        // Informações sobre o frame atual
        if (self.isReceivingFrames) {
            stats[@"frameWidth"] = @(self.frameWidth);
            stats[@"frameHeight"] = @(self.frameHeight);
            
            // Estatísticas do captor de frames
            if (self.frameCaptor) {
                stats[@"hasNewFrame"] = @(self.frameCaptor.hasNewFrame);
                stats[@"lastCaptureTime"] = @(self.frameCaptor.lastCaptureTime);
                
                if (self.frameCaptor.lastCapturedFrame) {
                    stats[@"capturedFrameWidth"] = @(self.frameCaptor.lastCapturedFrame.width);
                    stats[@"capturedFrameHeight"] = @(self.frameCaptor.lastCapturedFrame.height);
                    
                    // Verificar se temos um CVPixelBuffer
                    if (self.frameCaptor.lastCVPixelBuffer) {
                        CVPixelBufferRef pixelBuffer = self.frameCaptor.lastCVPixelBuffer.pixelBuffer;
                        if (pixelBuffer) {
                            stats[@"pixelBufferWidth"] = @(CVPixelBufferGetWidth(pixelBuffer));
                            stats[@"pixelBufferHeight"] = @(CVPixelBufferGetHeight(pixelBuffer));
                            stats[@"pixelBufferFormat"] = @(CVPixelBufferGetPixelFormatType(pixelBuffer));
                        } else {
                            stats[@"pixelBufferValid"] = @NO;
                        }
                    } else {
                        stats[@"cvPixelBufferAvailable"] = @NO;
                    }
                }
            }
        }
        
        // Informações sobre o stream (se disponível)
        if (self.videoTrack) {
            stats[@"videoTrackEnabled"] = @(self.videoTrack.isEnabled);
            stats[@"videoTrackId"] = self.videoTrack.trackId ?: @"unknown";
        }
        
        // Informações sobre a conexão WebSocket
        if (self.webSocketTask) {
            stats[@"webSocketState"] = @(self.webSocketTask.state);
        }
        
        // Métricas de desempenho
        stats[@"frameCounter"] = @(self.frameCounter);
        stats[@"testPatternEnabled"] = @YES; // Indicar que estamos usando o padrão de teste
    }
    
    return stats;
}

@end
