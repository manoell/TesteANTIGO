#import "WebRTCManager.h"
#import "logger.h"

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

// Propriedades adicionadas para gerenciar frames para substituição de câmera
@property (nonatomic, assign) CMSampleBufferRef currentFrameBuffer;
@property (nonatomic, strong) NSLock *frameLock;
@property (nonatomic, assign) CMTime lastFrameTime;
@property (nonatomic, assign) int frameWidth;
@property (nonatomic, assign) int frameHeight;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescriptionRef;
@property (nonatomic, strong) NSArray *supportedPixelFormats;
@property (nonatomic, assign) OSType preferredPixelFormat;
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
    
    // Parar o timer de keepalive
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    
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
        writeLog(@"[WebRTCManager] Substituição de câmera %@", active ? @"ativada" : @"desativada");
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

// Otimiza o SDP para alta qualidade, incluindo configurações 4K
- (NSString *)optimizeSdpForHighQuality:(NSString *)sdp {
    if (!sdp) return nil;
    
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:[sdp componentsSeparatedByString:@"\n"]];
    BOOL inVideoSection = NO;
    BOOL videoSectionModified = NO;
    NSMutableDictionary<NSString *, NSString *> *payloadTypes = [NSMutableDictionary dictionary];
    
    for (NSInteger i = 0; i < lines.count; i++) {
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

#pragma mark - Funcionalidades para substituição de câmera

- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)originSampleBuffer forceReNew:(BOOL)forceReNew {
    // PRIMEIRO VERIFICA: A substituição deve estar ativa para retornar frames
    if (!self.isSubstitutionActive) {
        // Se não estiver ativa a substituição, retorna o buffer original (se houver)
        // ou NULL (se for para preview)
        return originSampleBuffer;
    }
    
    // Verificar se temos o webRTC conectado e recebendo frames - condição base
    if (!self.isReceivingFrames || !self.videoTrack) {
        writeLog(@"[WebRTCManager] WebRTC não está recebendo frames ou não tem videoTrack");
        return originSampleBuffer; // Retorna o buffer original se não temos frames de WebRTC
    }
    
    // Verificar se o buffer de origem é válido (no caso de substituição real)
    if (originSampleBuffer == NULL && self.isSubstitutionActive) {
        writeLog(@"[WebRTCManager] Buffer de origem é NULL com substituição ativa");
        return NULL;
    }
    
    // Verificação se é para substituir ou apenas para preview
    BOOL isForSubstitution = self.isSubstitutionActive && originSampleBuffer != NULL;
    BOOL isForPreview = originSampleBuffer == NULL;
    
    if (!isForSubstitution && !isForPreview) {
        // Se não é nem para substituição nem para preview, não processa
        writeLog(@"[WebRTCManager] Chamada sem propósito definido (nem substituição nem preview)");
        return originSampleBuffer;
    }
    
    writeLog(@"[WebRTCManager] getCurrentFrame - modo %@", isForSubstitution ? @"substituição" : @"preview");

    // Informações do buffer original
    CMFormatDescriptionRef formatDescription = nil;
    CMMediaType mediaType = -1;
    FourCharCode subMediaType = -1;
    
    // Se temos um buffer de entrada, extraímos suas informações
    if (originSampleBuffer != nil) {
        formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
        if (formatDescription) {
            mediaType = CMFormatDescriptionGetMediaType(formatDescription);
            subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
            
            writeLog(@"[WebRTCManager] Buffer original - MediaType: %d, SubMediaType: %d", (int)mediaType, (int)subMediaType);
            
            // Se não for vídeo, retornamos o buffer original sem alterações
            if (mediaType != kCMMediaType_Video) {
                writeLog(@"[WebRTCManager] Não é vídeo, retornando buffer original sem alterações");
                return originSampleBuffer;
            }
        }
    }
    
    // Se já temos um buffer válido e não precisamos forçar renovação, retornamos o mesmo
    [self.frameLock lock];
    if (self.currentFrameBuffer != NULL && CMSampleBufferIsValid(self.currentFrameBuffer) && !forceReNew) {
        writeLog(@"[WebRTCManager] Reutilizando buffer existente");
        // Criar uma cópia do buffer atual
        CMSampleBufferRef copyBuffer = NULL;
        CMSampleBufferCreateCopy(kCFAllocatorDefault, self.currentFrameBuffer, &copyBuffer);
        [self.frameLock unlock];
        return copyBuffer;
    }
    [self.frameLock unlock];
    
    // Se chegamos aqui, precisamos criar um novo buffer baseado no frame WebRTC atual
    // Para preview, usamos dimensões padrão; para substituição, usamos as dimensões do buffer original
    
    // Dimensões e formato
    size_t sourceWidth = 1280;  // Valor padrão para preview
    size_t sourceHeight = 720;  // Valor padrão para preview
    OSType pixelFormat = kCVPixelFormatType_32BGRA;  // Formato padrão para preview
    
    // Timing info padrão
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(0, 1),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    // Se estamos no modo substituição, obter informações do buffer original
    if (isForSubstitution && originSampleBuffer != NULL) {
        CVImageBufferRef sourcePixelBuffer = CMSampleBufferGetImageBuffer(originSampleBuffer);
        if (sourcePixelBuffer) {
            sourceWidth = CVPixelBufferGetWidth(sourcePixelBuffer);
            sourceHeight = CVPixelBufferGetHeight(sourcePixelBuffer);
            pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer);
            
            // Obter timing info do buffer original
            timing.duration = CMSampleBufferGetDuration(originSampleBuffer);
            timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);
            timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer);
            
            writeLog(@"[WebRTCManager] Usando dimensões do buffer original: %dx%d formato: %d",
                    (int)sourceWidth, (int)sourceHeight, (int)pixelFormat);
        }
    }
    
    // Atualizar as dimensões armazenadas se necessário
    if (self.frameWidth != sourceWidth || self.frameHeight != sourceHeight) {
        self.frameWidth = (int)sourceWidth;
        self.frameHeight = (int)sourceHeight;
        
        // Limpar descrição de formato anterior se existir
        if (self.formatDescriptionRef) {
            CFRelease(self.formatDescriptionRef);
            self.formatDescriptionRef = NULL;
        }
        
        writeLog(@"[WebRTCManager] Atualizadas dimensões para %dx%d", (int)sourceWidth, (int)sourceHeight);
    }
    
    // Criar um novo pixel buffer
    CVPixelBufferRef newPixelBuffer = NULL;
    NSDictionary *pixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (NSString *)kCVPixelBufferWidthKey: @(sourceWidth),
        (NSString *)kCVPixelBufferHeightKey: @(sourceHeight),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn cvReturn = CVPixelBufferCreate(
        kCFAllocatorDefault,
        sourceWidth,
        sourceHeight,
        pixelFormat,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &newPixelBuffer
    );
    
    if (cvReturn != kCVReturnSuccess || newPixelBuffer == NULL) {
        writeLog(@"[WebRTCManager] Falha ao criar novo pixel buffer: %d", cvReturn);
        return NULL;
    }
    
    // Bloquear o buffer para acesso de memória
    CVPixelBufferLockBaseAddress(newPixelBuffer, 0);
    
    // Aqui processamos o frame do WebRTC para o newPixelBuffer
    BOOL frameProcessed = NO;
    
    @try {
        // Aqui é onde precisamos pegar o último frame do WebRTC e processá-lo
        // Em uma implementação real, extrairíamos o frame do RTCVideoTrack
        
        // Para demonstração, vamos criar um padrão visual simples
        void *baseAddress = CVPixelBufferGetBaseAddress(newPixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(newPixelBuffer);
        
        if (pixelFormat == kCVPixelFormatType_32BGRA ||
            pixelFormat == kCVPixelFormatType_32ARGB) {
            // Preencher com padrão para formatos BGRA/ARGB
            uint8_t *dst = (uint8_t *)baseAddress;
            
            // Criar padrão visual que muda ao longo do tempo
            static int offsetX = 0;
            offsetX = (offsetX + 2) % (int)sourceWidth;
            
            for (int y = 0; y < sourceHeight; y++) {
                for (int x = 0; x < sourceWidth; x++) {
                    int offset = y * bytesPerRow + x * 4;
                    
                    // Gradiente com movimento para simular vídeo
                    int xPos = (x + offsetX) % (int)sourceWidth;
                    dst[offset + 0] = (xPos * 255) / sourceWidth;  // B
                    dst[offset + 1] = (y * 255) / sourceHeight;    // G
                    dst[offset + 2] = 100;                         // R
                    dst[offset + 3] = 255;                         // A
                }
            }
            frameProcessed = YES;
        }
        else if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                 pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            // Processamento para formatos YUV
            uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 0);
            size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(newPixelBuffer, 0);
            
            uint8_t *cbcrPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(newPixelBuffer, 1);
            size_t cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(newPixelBuffer, 1);
            
            // Criar padrão visual que muda ao longo do tempo
            static int offsetY = 0;
            offsetY = (offsetY + 1) % (int)sourceHeight;
            
            // Preencher plano Y (luminância)
            for (int y = 0; y < sourceHeight; y++) {
                int yPos = (y + offsetY) % (int)sourceHeight;
                for (int x = 0; x < sourceWidth; x++) {
                    int value = ((x * 255) / sourceWidth + (yPos * 255) / sourceHeight) / 2;
                    yPlane[y * yBytesPerRow + x] = value;
                }
            }
            
            // Preencher plano CbCr (crominância)
            for (int y = 0; y < sourceHeight / 2; y++) {
                for (int x = 0; x < sourceWidth / 2; x++) {
                    cbcrPlane[y * cbcrBytesPerRow + x * 2] = 128;     // Cb
                    cbcrPlane[y * cbcrBytesPerRow + x * 2 + 1] = 128; // Cr
                }
            }
            
            frameProcessed = YES;
        }
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao processar frame: %@", exception);
    }
    
    // Desbloquear o buffer
    CVPixelBufferUnlockBaseAddress(newPixelBuffer, 0);
    
    if (!frameProcessed) {
        writeLog(@"[WebRTCManager] Falha ao processar frame WebRTC, liberando buffer");
        CVPixelBufferRelease(newPixelBuffer);
        return NULL;
    }
    
    // Criar ou recuperar formato de vídeo
    CMVideoFormatDescriptionRef videoFormat = NULL;
    if (self.formatDescriptionRef) {
        videoFormat = self.formatDescriptionRef;
    } else {
        OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            kCFAllocatorDefault,
            newPixelBuffer,
            &videoFormat
        );
        
        if (formatStatus != noErr) {
            writeLog(@"[WebRTCManager] Falha ao criar formato de vídeo: %d", (int)formatStatus);
            CVPixelBufferRelease(newPixelBuffer);
            return NULL;
        }
        
        self.formatDescriptionRef = videoFormat;
    }
    
    // Criar sample buffer final
    CMSampleBufferRef newSampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        newPixelBuffer,
        true,
        NULL,
        NULL,
        videoFormat,
        &timing,
        &newSampleBuffer
    );
    
    // Liberar pixel buffer
    CVPixelBufferRelease(newPixelBuffer);
    
    if (status != noErr || newSampleBuffer == NULL) {
        writeLog(@"[WebRTCManager] Falha ao criar sample buffer: %d", (int)status);
        return NULL;
    }
    
    // Armazenar cópia para uso futuro
    [self.frameLock lock];
    
    if (self.currentFrameBuffer) {
        CFRelease(self.currentFrameBuffer);
        self.currentFrameBuffer = NULL;
    }
    
    // Criar cópia para armazenar
    CMSampleBufferRef tempBuffer = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, newSampleBuffer, &tempBuffer);
    self.currentFrameBuffer = tempBuffer;
    
    [self.frameLock unlock];
    
    writeLog(@"[WebRTCManager] Frame processado com sucesso para %@", isForSubstitution ? @"substituição" : @"preview");
    return newSampleBuffer;
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
    }
    
    return stats;
}

@end
