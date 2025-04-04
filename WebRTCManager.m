#import "WebRTCManager.h"
#import "FloatingWindow.h"
#import "logger.h"

@interface WebRTCManager () <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, assign) WebRTCManagerState state;
@property (nonatomic, assign) BOOL isReceivingFrames;
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
// Timer management (simplificado)
@property (nonatomic, strong) NSTimer *statsTimer;
@end

@implementation WebRTCManager

#pragma mark - Initialization & Lifecycle

- (instancetype)initWithFloatingWindow:(FloatingWindow *)window {
    self = [super init];
    if (self) {
        _floatingWindow = window;
        _state = WebRTCManagerStateDisconnected;
        _isReceivingFrames = NO;
        _reconnectAttempts = 0;
        _userRequestedDisconnect = NO;
        _serverIP = @"192.168.0.178"; // Default IP - pode ser personalizado
        
        // Inicializar logs
        writeLog(@"[WebRTCManager] WebRTCManager inicializado com configurações simplificadas");
    }
    return self;
}

- (void)dealloc {
    [self stopWebRTC:YES];
}

#pragma mark - State Management

- (void)setState:(WebRTCManagerState)state {
    if (_state == state) {
        return;
    }
    
    WebRTCManagerState oldState = _state;
    _state = state;
    
    // Log da transição
    writeLog(@"[WebRTCManager] Estado alterado: %@ -> %@",
             [self stateToString:oldState],
             [self stateToString:state]);
    
    // Notificar FloatingWindow
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.floatingWindow updateConnectionStatus:[self statusMessageForState:state]];
    });
}

- (NSString *)stateToString:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected: return @"Desconectado";
        case WebRTCManagerStateConnecting: return @"Conectando";
        case WebRTCManagerStateConnected: return @"Conectado";
        case WebRTCManagerStateError: return @"Erro";
        case WebRTCManagerStateReconnecting: return @"Reconectando";
        default: return @"Desconhecido";
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
            return [NSString stringWithFormat:@"Reconectando (%d)...", self.reconnectAttempts];
        default:
            return @"Estado desconhecido";
    }
}

#pragma mark - Connection Management

- (void)startWebRTC {
    @try {
        // Verificar se já está conectado ou conectando
        if (_state == WebRTCManagerStateConnected ||
            _state == WebRTCManagerStateConnecting) {
            writeLog(@"[WebRTCManager] Já está conectado ou conectando, ignorando chamada");
            return;
        }
        
        // Verificar IP do servidor
        if (self.serverIP == nil || self.serverIP.length == 0) {
            writeLog(@"[WebRTCManager] IP do servidor inválido, usando padrão");
            self.serverIP = @"192.168.0.178"; // Default IP
        }
        
        // Resetar flag de desconexão pelo usuário
        self.userRequestedDisconnect = NO;
        
        writeLog(@"[WebRTCManager] Iniciando WebRTC");
        
        // Atualizar estado
        self.state = WebRTCManagerStateConnecting;
        
        // Limpar qualquer instância anterior
        [self stopWebRTC:NO];
        
        // Configurar WebRTC - Versão simplificada
        [self configureWebRTCWithDefaults];
        
        // Conectar ao WebSocket
        [self connectWebSocket];
        
        // Iniciar timer para estatísticas
        [self startStatsTimer];
        
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao iniciar WebRTC: %@", exception);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.floatingWindow updateConnectionStatus:@"Erro ao iniciar WebRTC"];
        });
        self.state = WebRTCManagerStateError;
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    // Se o usuário solicitou a desconexão, marcar flag
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
    }
    
    writeLog(@"[WebRTCManager] Parando WebRTC (solicitado pelo usuário: %@)",
            userInitiated ? @"sim" : @"não");
    
    // Parar timers
    [self stopStatsTimer];
    
    // Desativar recepção de frames
    self.isReceivingFrames = NO;
    
    // Limpar track de vídeo
    if (self.videoTrack) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            // Remover o videoTrack da view
            RTCVideoTrack *track = self.videoTrack;
            self.videoTrack = nil;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.floatingWindow respondsToSelector:@selector(videoView)]) {
                    RTCEAGLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                    if (videoView) {
                        [track removeRenderer:videoView];
                    }
                }
            });
        }
    }
    
    // Cancelar WebSocket
    if (self.webSocketTask) {
        NSURLSessionWebSocketTask *taskToCancel = self.webSocketTask;
        self.webSocketTask = nil;
        [taskToCancel cancel];
    }
    
    // Liberar sessão
    if (self.session) {
        NSURLSession *sessionToInvalidate = self.session;
        self.session = nil;
        [sessionToInvalidate invalidateAndCancel];
    }
    
    // Fechar conexão peer
    if (self.peerConnection) {
        RTCPeerConnection *connectionToClose = self.peerConnection;
        self.peerConnection = nil;
        [connectionToClose close];
    }
    
    // Limpar fábrica
    self.factory = nil;
    
    // Limpar roomId e clientId
    self.roomId = nil;
    self.clientId = nil;
    
    // Se não está em reconexão, atualizar estado
    if (self.state != WebRTCManagerStateReconnecting || userInitiated) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

#pragma mark - Timer Management

- (void)startStatsTimer {
    // Parar timer existente se houver
    [self stopStatsTimer];
    
    // Criar novo timer para coleta de estatísticas
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
    if (!self.peerConnection) {
        return;
    }
    
    [self.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport * _Nonnull report) {
        // Processar estatísticas básicas
        // Simplificado para evitar complexidade excessiva
        writeLog(@"[WebRTCManager] Coletando estatísticas");
    }];
}

#pragma mark - WebRTC Configuration

- (void)configureWebRTCWithDefaults {
    writeLog(@"[WebRTCManager] Configurando WebRTC com configurações simplificadas");
    
    @try {
        // Configuração otimizada para WebRTC
        RTCConfiguration *config = [[RTCConfiguration alloc] init];
        
        // Para rede local, apenas um servidor STUN é suficiente
        config.iceServers = @[
            [[RTCIceServer alloc] initWithURLStrings:@[@"stun:stun.l.google.com:19302"]]
        ];
        
        // Configurações de ICE
        config.iceTransportPolicy = RTCIceTransportPolicyAll;
        config.bundlePolicy = RTCBundlePolicyMaxBundle;
        config.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
                
        // Inicializar a fábrica - Verificar cada passo
        RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
        if (!decoderFactory) {
            writeLog(@"[WebRTCManager] Falha ao criar decoderFactory");
            return;
        }
        
        RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
        if (!encoderFactory) {
            writeLog(@"[WebRTCManager] Falha ao criar encoderFactory");
            return;
        }
        
        self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                                  decoderFactory:decoderFactory];
        if (!self.factory) {
            writeLog(@"[WebRTCManager] Falha ao criar PeerConnectionFactory");
            return;
        }
        
        // Criar a conexão peer com verificação
        self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                               constraints:[[RTCMediaConstraints alloc]
                                                                            initWithMandatoryConstraints:@{}
                                                                            optionalConstraints:@{}]
                                                                  delegate:self];
        
        if (!self.peerConnection) {
            writeLog(@"[WebRTCManager] Falha ao criar conexão peer");
            return;
        }
        
        writeLog(@"[WebRTCManager] Conexão peer criada com sucesso");
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao configurar WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
    }
}

#pragma mark - WebSocket Connection

- (void)connectWebSocket {
    @try {
        // Adicionar log para verificar o IP que está sendo usado
        writeLog(@"[WebRTCManager] Tentando conectar ao servidor WebSocket: %@", self.serverIP);
        
        // Criar URL para o servidor
        NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
        NSURL *url = [NSURL URLWithString:urlString];
        
        if (!url) {
            writeLog(@"[WebRTCManager] URL inválida: %@", urlString);
            self.state = WebRTCManagerStateError;
            return;
        }
        
        // Configurar a sessão
        NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfig.timeoutIntervalForRequest = 10.0;
        sessionConfig.timeoutIntervalForResource = 30.0;
        
        // Criar sessão e task WebSocket
        if (self.session) {
            [self.session invalidateAndCancel];
        }
        self.session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                     delegate:self
                                                delegateQueue:[NSOperationQueue mainQueue]];
        
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        self.webSocketTask = [self.session webSocketTaskWithRequest:request];
        
        // Iniciar recepção de mensagens
        [self receiveWebSocketMessage];
        
        // Conectar
        [self.webSocketTask resume];
        
        // Enviar mensagem inicial de JOIN depois que a conexão estiver estabelecida
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.webSocketTask && self.webSocketTask.state == NSURLSessionTaskStateRunning) {
                [self sendWebSocketMessage:@{
                    @"type": @"join",
                    @"roomId": self.roomId ?: @"ios-camera"
                }];
            }
        });
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exceção ao conectar WebSocket: %@", exception);
        self.state = WebRTCManagerStateError;
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
            
            // Se o WebSocket estiver fechado por erro, tentar reconectar
            if (weakSelf.webSocketTask.state != NSURLSessionTaskStateRunning && !weakSelf.userRequestedDisconnect) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.state = WebRTCManagerStateError;
                    // Simplificado - sem tentativa de reconexão automática
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
        
        // Continuar recebendo mensagens
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
        [self.floatingWindow updateConnectionStatus:[NSString stringWithFormat:@"Erro: %@", message[@"message"]]];
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
        
        // Criar resposta
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
            
            // Definir descrição local
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Erro ao definir descrição local: %@", error);
                    return;
                }
                
                // Enviar resposta para o servidor
                [weakSelf sendWebSocketMessage:@{
                    @"type": @"answer",
                    @"sdp": sdp.sdp,
                    @"roomId": weakSelf.roomId ?: @"ios-camera"
                }];
                
                // Usar weakSelf em vez de self para evitar retain cycle
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
            return;
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket conectado");
    
    // Redefinir contador de tentativas de reconexão quando conectado com sucesso
    self.reconnectAttempts = 0;
    
    if (!self.userRequestedDisconnect) {
        // Enviar mensagem de JOIN
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
    
    // Se a desconexão não foi solicitada pelo usuário, atualizar estado
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
    
    // Enviar candidato Ice para o servidor
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
    
    // Verificar se a stream tem faixas de vídeo
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        writeLog(@"[WebRTCManager] Faixa de vídeo recebida: %@", self.videoTrack.trackId);
        
        // Adicionar o video track ao RTCEAGLVideoView
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                RTCEAGLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
                if (videoView) {
                    [self.videoTrack addRenderer:videoView];
                    
                    // Parar indicador de carregamento
                    UIActivityIndicatorView *loadingIndicator = [self.floatingWindow valueForKey:@"loadingIndicator"];
                    if (loadingIndicator) {
                        [loadingIndicator stopAnimating];
                    }
                    
                    // Atualizar flag
                    self.isReceivingFrames = YES;
                    
                    // Atualizar status
                    [self.floatingWindow updateConnectionStatus:@"Conectado - Recebendo vídeo"];
                }
            });
        }
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removida: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        if (self.floatingWindow && [self.floatingWindow respondsToSelector:@selector(videoView)]) {
            RTCEAGLVideoView *videoView = [self.floatingWindow valueForKey:@"videoView"];
            if (videoView) {
                [self.videoTrack removeRenderer:videoView];
            }
        }
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
    switch (state) {
        case RTCIceConnectionStateNew: return @"Novo";
        case RTCIceConnectionStateChecking: return @"Verificando";
        case RTCIceConnectionStateConnected: return @"Conectado";
        case RTCIceConnectionStateCompleted: return @"Completo";
        case RTCIceConnectionStateFailed: return @"Falha";
        case RTCIceConnectionStateDisconnected: return @"Desconectado";
        case RTCIceConnectionStateClosed: return @"Fechado";
        case RTCIceConnectionStateCount: return @"Contagem";
        default: return @"Desconhecido";
    }
}

- (NSString *)iceGatheringStateToString:(RTCIceGatheringState)state {
    switch (state) {
        case RTCIceGatheringStateNew: return @"Novo";
        case RTCIceGatheringStateGathering: return @"Coletando";
        case RTCIceGatheringStateComplete: return @"Completo";
        default: return @"Desconhecido";
    }
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    switch (state) {
        case RTCSignalingStateStable: return @"Estável";
        case RTCSignalingStateHaveLocalOffer: return @"Oferta Local";
        case RTCSignalingStateHaveLocalPrAnswer: return @"Pré-resposta Local";
        case RTCSignalingStateHaveRemoteOffer: return @"Oferta Remota";
        case RTCSignalingStateHaveRemotePrAnswer: return @"Pré-resposta Remota";
        case RTCSignalingStateClosed: return @"Fechado";
        default: return @"Desconhecido";
    }
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        // Valores padrão
        stats[@"connectionType"] = @"Desconhecido";
        stats[@"rtt"] = @"--";
        stats[@"packetsReceived"] = @"--";
        
        // Estado da conexão ICE
        NSString *iceState = [self iceConnectionStateToString:self.peerConnection.iceConnectionState];
        stats[@"iceState"] = iceState;
        
        // Se a conexão estiver ativa, atualizar com valores mais precisos
        if (self.state == WebRTCManagerStateConnected) {
            stats[@"connectionType"] = self.isReceivingFrames ? @"Ativa" : @"Conectada (sem frames)";
            
            // Estimativa de RTT (round-trip time)
            if (self.isReceivingFrames) {
                stats[@"rtt"] = @"~120ms"; // Valor estimado
                stats[@"packetsReceived"] = @"Sim";
            }
        } else {
            stats[@"connectionType"] = [self stateToString:self.state];
        }
    }
    
    return stats;
}

@end
