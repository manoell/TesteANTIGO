#import "WebRTCManager.h"
#import "logger.h"

@interface WebRTCManager () <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>
@property (nonatomic, assign, readwrite) WebRTCManagerState state;
@property (nonatomic, assign, readwrite) BOOL isReceivingFrames;
@property (nonatomic, assign) int reconnectAttempts;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSString *roomId;
@property (nonatomic, strong) NSString *clientId;
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
        
        writeLog(@"[WebRTCManager] Initialized");
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
    
    writeLog(@"[WebRTCManager] State changed: %@ -> %@",
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
        stateStrings = @[@"Disconnected", @"Connecting", @"Connected", @"Error", @"Reconnecting"];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Unknown";
    return stateStrings[state];
}

- (NSString *)statusMessageForState:(WebRTCManagerState)state {
    switch (state) {
        case WebRTCManagerStateDisconnected:
            return @"Disconnected";
        case WebRTCManagerStateConnecting:
            return @"Connecting to server...";
        case WebRTCManagerStateConnected:
            return self.isReceivingFrames ? @"Connected - Receiving stream" : @"Connected - Waiting for stream";
        case WebRTCManagerStateError:
            return @"Connection error";
        case WebRTCManagerStateReconnecting:
            return [NSString stringWithFormat:@"Reconnecting (%d)...", self.reconnectAttempts];
        default:
            return @"Unknown state";
    }
}

#pragma mark - Connection Management

- (void)startWebRTC {
    if (_state == WebRTCManagerStateConnected || _state == WebRTCManagerStateConnecting) {
        writeLog(@"[WebRTCManager] Already connected or connecting, ignoring call");
        return;
    }
    
    if (self.serverIP.length == 0) {
        self.serverIP = @"192.168.0.178";
    }
    
    self.userRequestedDisconnect = NO;
    writeLog(@"[WebRTCManager] Starting WebRTC");
    
    self.state = WebRTCManagerStateConnecting;
    [self stopWebRTC:NO];
    
    @try {
        [self configureWebRTCWithDefaults];
        [self connectWebSocket];
        [self startStatsTimer];
    } @catch (NSException *exception) {
        writeLog(@"[WebRTCManager] Exception when starting WebRTC: %@", exception);
        self.state = WebRTCManagerStateError;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate didUpdateConnectionStatus:@"Error starting WebRTC"];
        });
    }
}

- (void)stopWebRTC:(BOOL)userInitiated {
    if (userInitiated) {
        self.userRequestedDisconnect = YES;
    }
    
    writeLog(@"[WebRTCManager] Stopping WebRTC (user initiated: %@)",
            userInitiated ? @"yes" : @"no");
    
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
        writeLog(@"[WebRTCManager] Cannot send 'bye', WebSocket not connected");
        return;
    }
    
    writeLog(@"[WebRTCManager] Sending 'bye' message to server");
    
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
        // Process statistics if needed
    }];
}

#pragma mark - WebRTC Configuration

- (void)configureWebRTCWithDefaults {
    writeLog(@"[WebRTCManager] Configuring WebRTC");
    
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
        writeLog(@"[WebRTCManager] Failed to create codec factories");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    self.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                              decoderFactory:decoderFactory];
    
    if (!self.factory) {
        writeLog(@"[WebRTCManager] Failed to create PeerConnectionFactory");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    self.peerConnection = [self.factory peerConnectionWithConfiguration:config
                                                           constraints:[[RTCMediaConstraints alloc]
                                                                        initWithMandatoryConstraints:@{}
                                                                        optionalConstraints:@{}]
                                                              delegate:self];
    
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Failed to create peer connection");
        self.state = WebRTCManagerStateError;
        return;
    }
    
    writeLog(@"[WebRTCManager] Peer connection created successfully");
}

#pragma mark - WebSocket Connection

- (void)connectWebSocket {
    writeLog(@"[WebRTCManager] Attempting to connect to WebSocket server: %@", self.serverIP);
    
    NSString *urlString = [NSString stringWithFormat:@"ws://%@:8080", self.serverIP];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (!url) {
        writeLog(@"[WebRTCManager] Invalid URL: %@", urlString);
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
    
    // Send join message after short delay to ensure socket is connected
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
        writeLog(@"[WebRTCManager] Attempt to send message with WebSocket not connected");
        return;
    }
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message
                                                      options:0
                                                        error:&error];
    if (error) {
        writeLog(@"[WebRTCManager] Error serializing JSON message: %@", error);
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:jsonString]
                    completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Error sending WebSocket message: %@", error);
        }
    }];
}

- (void)receiveWebSocketMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Error receiving WebSocket message: %@", error);
            
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
                writeLog(@"[WebRTCManager] Error parsing JSON message: %@", jsonError);
                return;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleWebSocketMessage:jsonDict];
            });
        }
        
        // Continue listening for messages if socket is still active
        if (weakSelf.webSocketTask && weakSelf.webSocketTask.state == NSURLSessionTaskStateRunning) {
            [weakSelf receiveWebSocketMessage];
        }
    }];
}

- (void)handleWebSocketMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    
    if (!type) {
        writeLog(@"[WebRTCManager] Received message without type");
        return;
    }
    
    writeLog(@"[WebRTCManager] Message received: %@", type);
    
    if ([type isEqualToString:@"offer"]) {
        [self handleOfferMessage:message];
    } else if ([type isEqualToString:@"answer"]) {
        [self handleAnswerMessage:message];
    } else if ([type isEqualToString:@"ice-candidate"]) {
        [self handleCandidateMessage:message];
    } else if ([type isEqualToString:@"user-joined"]) {
        writeLog(@"[WebRTCManager] New user joined room: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"user-left"]) {
        writeLog(@"[WebRTCManager] User left room: %@", message[@"userId"]);
    } else if ([type isEqualToString:@"error"]) {
        writeLog(@"[WebRTCManager] Error received from server: %@", message[@"message"]);
        [self.delegate didUpdateConnectionStatus:[NSString stringWithFormat:@"Error: %@", message[@"message"]]];
    }
}

#pragma mark - SDP Message Handling

- (void)handleOfferMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Received offer but no peer connection exists");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Offer received without SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Error setting remote description: %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Remote description set successfully, creating answer");
        
        RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:@{
            @"OfferToReceiveVideo": @"true",
            @"OfferToReceiveAudio": @"false"
        } optionalConstraints:nil];
        
        [weakSelf.peerConnection answerForConstraints:constraints
                               completionHandler:^(RTCSessionDescription * _Nullable sdp, NSError * _Nullable error) {
            if (error) {
                writeLog(@"[WebRTCManager] Error creating answer: %@", error);
                return;
            }
            
            [weakSelf.peerConnection setLocalDescription:sdp completionHandler:^(NSError * _Nullable error) {
                if (error) {
                    writeLog(@"[WebRTCManager] Error setting local description: %@", error);
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
        writeLog(@"[WebRTCManager] Received answer but no peer connection exists");
        return;
    }
    
    NSString *sdp = message[@"sdp"];
    if (!sdp) {
        writeLog(@"[WebRTCManager] Answer received without SDP");
        return;
    }
    
    RTCSessionDescription *description = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:sdp];
    
    __weak typeof(self) weakSelf = self;
    [self.peerConnection setRemoteDescription:description completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Error setting remote description (answer): %@", error);
            return;
        }
        
        writeLog(@"[WebRTCManager] Remote answer set successfully");
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = WebRTCManagerStateConnected;
        });
    }];
}

- (void)handleCandidateMessage:(NSDictionary *)message {
    if (!self.peerConnection) {
        writeLog(@"[WebRTCManager] Received candidate but no peer connection exists");
        return;
    }
    
    NSString *candidate = message[@"candidate"];
    NSString *sdpMid = message[@"sdpMid"];
    NSNumber *sdpMLineIndex = message[@"sdpMLineIndex"];
    
    if (!candidate || !sdpMid || !sdpMLineIndex) {
        writeLog(@"[WebRTCManager] Candidate received with invalid parameters");
        return;
    }
    
    RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc] initWithSdp:candidate
                                                         sdpMLineIndex:[sdpMLineIndex intValue]
                                                                sdpMid:sdpMid];
    
    [self.peerConnection addIceCandidate:iceCandidate completionHandler:^(NSError * _Nullable error) {
        if (error) {
            writeLog(@"[WebRTCManager] Error adding Ice candidate: %@", error);
        }
    }];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    writeLog(@"[WebRTCManager] WebSocket connected");
    
    self.reconnectAttempts = 0;
    
    if (!self.userRequestedDisconnect) {
        self.roomId = self.roomId ?: @"ios-camera";
        [self sendWebSocketMessage:@{
            @"type": @"join",
            @"roomId": self.roomId
        }];
        
        writeLog(@"[WebRTCManager] Sent JOIN message to room: %@", self.roomId);
    }
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSString *reasonStr = [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] ?: @"Unknown";
    writeLog(@"[WebRTCManager] WebSocket closed with code: %ld, reason: %@", (long)closeCode, reasonStr);
    
    if (!self.userRequestedDisconnect) {
        self.state = WebRTCManagerStateDisconnected;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        writeLog(@"[WebRTCManager] WebSocket completed with error: %@", error);
        
        if (!self.userRequestedDisconnect) {
            self.state = WebRTCManagerStateError;
        }
    }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    writeLog(@"[WebRTCManager] Ice candidate generated");
    
    [self sendWebSocketMessage:@{
        @"type": @"ice-candidate",
        @"candidate": candidate.sdp,
        @"sdpMid": candidate.sdpMid,
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"roomId": self.roomId ?: @"ios-camera"
    }];
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    writeLog(@"[WebRTCManager] Ice candidates removed: %lu", (unsigned long)candidates.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    NSString *stateString = [self iceConnectionStateToString:newState];
    writeLog(@"[WebRTCManager] Ice connection state changed: %@", stateString);
    
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
    writeLog(@"[WebRTCManager] Ice gathering state changed: %@", [self iceGatheringStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)newState {
    writeLog(@"[WebRTCManager] Signaling state changed: %@", [self signalingStateToString:newState]);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream added: %@ (audio: %lu, video: %lu)",
            stream.streamId, (unsigned long)stream.audioTracks.count, (unsigned long)stream.videoTracks.count);
    
    if (stream.videoTracks.count > 0) {
        self.videoTrack = stream.videoTracks[0];
        
        writeLog(@"[WebRTCManager] Video track received: %@", self.videoTrack.trackId);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate didReceiveVideoTrack:self.videoTrack];
            self.isReceivingFrames = YES;
            [self.delegate didUpdateConnectionStatus:@"Connected - Receiving video"];
        });
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    writeLog(@"[WebRTCManager] Stream removed: %@", stream.streamId);
    
    if ([stream.videoTracks containsObject:self.videoTrack]) {
        self.videoTrack = nil;
        self.isReceivingFrames = NO;
    }
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    writeLog(@"[WebRTCManager] Negotiation needed");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    writeLog(@"[WebRTCManager] Data channel opened: %@", dataChannel.label);
}

#pragma mark - Helper Methods

- (NSString *)iceConnectionStateToString:(RTCIceConnectionState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[
            @"New", @"Checking", @"Connected", @"Completed",
            @"Failed", @"Disconnected", @"Closed", @"Count"
        ];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Unknown";
    return stateStrings[state];
}

- (NSString *)iceGatheringStateToString:(RTCIceGatheringState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[@"New", @"Gathering", @"Complete"];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Unknown";
    return stateStrings[state];
}

- (NSString *)signalingStateToString:(RTCSignalingState)state {
    static NSArray *stateStrings = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stateStrings = @[
            @"Stable", @"Have Local Offer", @"Have Local PR Answer",
            @"Have Remote Offer", @"Have Remote PR Answer", @"Closed"
        ];
    });
    
    if (state < 0 || state >= stateStrings.count) return @"Unknown";
    return stateStrings[state];
}

- (NSDictionary *)getConnectionStats {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    if (self.peerConnection) {
        stats[@"connectionType"] = @"Unknown";
        stats[@"iceState"] = [self iceConnectionStateToString:self.peerConnection.iceConnectionState];
        
        if (self.state == WebRTCManagerStateConnected) {
            stats[@"connectionType"] = self.isReceivingFrames ? @"Active" : @"Connected (no frames)";
        } else {
            stats[@"connectionType"] = [self stateToString:self.state];
        }
    }
    
    return stats;
}

@end
