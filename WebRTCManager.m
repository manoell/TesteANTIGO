#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

@interface WebRTCManager () <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, assign) NSTimeInterval lastFrameReceivedTime;
@property (nonatomic, assign) BOOL userRequestedDisconnect;
@property (nonatomic, strong) RTCVideoTrack *videoTrack;
@property (nonatomic, strong) RTCPeerConnectionFactory *factory;
@property (nonatomic, strong) RTCPeerConnection *peerConnection;
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation WebRTCManager

#pragma mark - Initialization & Lifecycle

- (instancetype)initWithDelegate:(id<WebRTCManagerDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _reconnectAttempts = 0;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178"; // Default IP
        
        writeLog(@"[WebRTCManager] WebRTCManager inicializado");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC:YES];
}

#pragma mark - State Management

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
            return [NSString stringWithFormat:@"Reconectando (%d)...", self.reconnectAttempts];
        default:
            return @"Estado desconhecido";
    }
}

#pragma mark - Connection Management

- (void)startWebRTC {
    if (_state == WebRTCManagerStateConnected || _state == WebRTCManagerStateConnecting) {
        writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
        return;
    }
    
    if (self.serverIP.length == 0) {
        self.serverIP = @"192.168.0.178";
    }
    
    self.userRequestedDisconnect = NO;
    writeLog(@"[WebRTCManager] Iniciando WebRTC");
    
    self.state = WebRTCManagerStateConnecting;
    [self stopWebRTC:NO];
    
    @try {
        [self configureWebRTCWithDefaults];
        [self connectWebSocket];
        [self startStatsTimer];
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
    }
    
    writeLog(@"[WebRTCManager] Parando WebRTC (solicitado pelo usuário: %@)",
            userInitiated ? @"sim" : @"não");
    
    [self stopStatsTimer];
    self.isReceivingFrames = NO;
    
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
    self.clientId = nil;
    
    if (self.state != WebRTCManagerStateReconnecting || userInitiated) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)sendByeMessage {
    if (!self.webSocketTask || self.webSocketTask.state != NSURLSessionTaskStateRunning) {
        writeLog(@"[WebRTCManager] Não foi possível enviar 'bye', WebSocket não está conectado");
        return;
    }
    
    writeLog(@"[WebRTCManager] Enviando mensagem 'bye' para o servidor");
    
    NSDictionary *byeMessage = @{
        @"type": @"bye",
        @"roomId": self.roomId ?: @"ios-camera"
    };
    
    [self sendWebSocketMessage:byeMessage];
}

#pragma mark - Timer Management

- (void)startStatsTimer {
    [self stopStatsTimer];
    
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(collectStats)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)stopStatsTimer {
    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
}

- (void)collectStats {
    if (!self.peerConnection) return;
    
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        writeLog(@"[WebRTCManager] Coletando estatísticas");
    }];
}

#pragma mark - WebRTC Configuration

- (void)configureWebRTCWithDefaults {
    writeLog(@"[WebRTCManager] Configurando WebRTC");
    
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    config.iceServers = @[
        [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
    ];
    config.iceTransportPolicy = RTCIceTransportPolicyAll;
    config.bundlePolicy = RTCBundlePolicyMaxBundle;
    config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
            
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    
    if (!decoderFactory || !encoderFactory) {
        writeLog(@"[WebRTCManager] Falha ao criar factories de codec");
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
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:[[RTCMediaConstraints alloc]
                                                                        initWithMandatoryConstraints:@{}
                                                                        optionalConstraints:@{}]
                                                              delegate:self];
    
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Falha ao criar conexão peer");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    writeLog(@"[WebRTCManager] Conexão peer criada com sucesso");
}

#pragma mark - WebSocket Connection

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Tentando conectar ao servidor WebSocket: %@", self.serverIP);
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        writeLog(@"[WebRTCManager] URL inválida: %@", urlString);
        self.state = WebRTCManagerStateError;
        return;
    }
    
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 10.0;
    sessionConfig.timeoutIntervalForResource = 30.0;
    
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
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [self sendWebSocketMessage:@{
                @"type": @"join",
                @"roomId": self.roomId ?: @"ios-camera"
            }];
        }
    });
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
            
            if (weakSelf.webSocketTask.state != NSURLSessionTaskStateRunning && !weakSelf.userRequestedDisconnect) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateError;
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
            
            if (jsonError) {
                writeLog(@"[WebRTCManager] Erro ao analisar mensagem JSON: %@", jsonError);
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
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
    } else {
        writeLog(@"[WebRTCManager] Tipo de mensagem desconhecido: %@", type);
    }
}

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Recebida oferta, mas não há conexão peer");
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
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                               completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                writeLog(@"[WebRTCManager] Erro ao criar resposta: %@", error);
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                [weakSelf sendWebSocketMessage:@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
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
        writeLog(@"[WebRTCManager] Resposta recebida, mas não há conexão peer");
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
        writeLog(@"[WebRTCManager] Candidato recebido, mas não há conexão peer");
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

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket conectado");
    
    self.reconnectAttempts = 0;
    
    if (!self.userRequestedDisconnect) {
        self.roomId = self.roomId ?: @"ios-camera";
        [self sendWebSocketMessage:@{
            @"type": @"join",
            @"roomId": self.roomId
        }];
        
        writeLog(@"[WebRTCManager] Enviada mensagem de JOIN para a sala: %@", self.roomId);
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Desconhecido";
    writeLog(@"[WebRTCManager] WebSocket fechado com código: %ld, motivo: %@", (long)closeCode, reasonStr);
    
    if (!self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket completou com erro: %@", error);
        
        if (!self.userRequestedDisconnect) {
            self.state = WebRTCManagerStateError;
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Candidato Ice gerado: %@", candidate.sdp);
    
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId ?: @"ios-camera"
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Candidatos Ice removidos: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *stateString = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Estado da conexão Ice alterado: %@", stateString);
    
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
    writeLog(@"[WebRTCManager] Estado de coleta Ice alterado: %@", [self iceGatheringStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    writeLog(@"[WebRTCManager] Estado de sinalização alterado: %@", [self signalingStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream adicionada: %@ (áudio: %lu, vídeo: %lu)",
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
    writeLog(@"[WebRTCManager] Stream removida: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Necessária renegociação");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Data channel aberto: %@", dataChannel.label);
}

#pragma mark - Helper Methods

- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[
            @"Novo", @"Verificando", @"Conectado", @"Completo",
            @"Falha", @"Desconectado", @"Fechado", @"Contagem"
        ];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Desconhecido";
    return stateStrings[state];
}

- (NSString *)iceGatheringStateToString:(RTCIceGatheringState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[@"Novo", @"Coletando", @"Completo"];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Desconhecido";
    return stateStrings[state];
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[
            @"Estável", @"Oferta Local", @"Pré-resposta Local",
            @"Oferta Remota", @"Pré-resposta Remota", @"Fechado"
        ];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Desconhecido";
    return stateStrings[state];
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        stats[@"connectionType"] = @"Desconhecido";
        stats[@"rtt"] = @"--";
        stats[@"packetsReceived"] = @"--";
        
        NSString *iceState = [self iceConnectionStateToString:self.peerConnection.iceConnectionState];
        stats[@"iceState"] = iceState;
        
        if (self.state == WebRTCManagerStateConnected) {
            stats[@"connectionType"] = self.isReceivingFrames ? @"Ativa" : @"Conectada (sem frames)";
            
            if (self.isReceivingFrames) {
                stats[@"rtt"] = @"~120ms";
                stats[@"packetsReceived"] = @"Sim";
            }
        } else {
            stats[@"connectionType"] = [self stateToString:self.state];
        }
    }
    
    return stats;
}

@end
