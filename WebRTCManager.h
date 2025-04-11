#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;

typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,
    WebRTCManagerStateConnecting,
    WebRTCManagerStateConnected,
    WebRTCManagerStateError,
    WebRTCManagerStateReconnecting
};

@protocol WebRTCManagerDelegate <NSObject>
- (void)didUpdateConnectionStatus:(NSString *)status;
- (void)didReceiveVideoTrack:(RTCVideoTrack *)videoTrack;
- (void)didChangeConnectionState:(WebRTCManagerState)state;
@end

@interface WebRTCManager : NSObject

@property (nonatomic, weak) id<WebRTCManagerDelegate> delegate;
@property (nonatomic, strong) NSString *serverIP;
@property (nonatomic, assign, readonly) WebRTCManagerState state;
@property (nonatomic, assign, readonly) BOOL isReceivingFrames;

// Inicializa o gerenciador WebRTC com o delegate fornecido
- (instancetype)initWithDelegate:(id<WebRTCManagerDelegate>)delegate;

// Inicia a conexão WebRTC com as configurações atuais
- (void)startWebRTC;

// Para a conexão WebRTC
// @param userInitiated YES se a ação foi iniciada pelo usuário
- (void)stopWebRTC:(BOOL)userInitiated;

// Envia mensagem de despedida para o servidor antes de desconectar
- (void)sendByeMessage;

// Retorna estatísticas sobre a conexão atual
- (NSDictionary *)getConnectionStats;

@end

#endif /* WEBRTCMANAGER_H */
