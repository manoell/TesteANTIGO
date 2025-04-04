#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;

/**
 * Estado de conexão do WebRTCManager
 */
typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,    // Desconectado do servidor WebRTC
    WebRTCManagerStateConnecting,      // Tentando conectar ao servidor WebRTC
    WebRTCManagerStateConnected,       // Conectado e pronto para receber frames
    WebRTCManagerStateError,           // Erro na conexão WebRTC
    WebRTCManagerStateReconnecting     // Reconectando após falha
};

/**
 * WebRTCManager
 *
 * Classe responsável pelo gerenciamento da conexão WebRTC.
 * Versão simplificada para foco na funcionalidade básica.
 */
@interface WebRTCManager : NSObject

/**
 * Referência à janela flutuante para atualização de UI
 */
@property (nonatomic, weak) FloatingWindow *floatingWindow;

/**
 * Endereço IP do servidor
 */
@property (nonatomic, strong) NSString *serverIP;

/**
 * Inicializa o gerenciador com referência à janela flutuante.
 * @param window FloatingWindow para atualização de interface.
 * @return Nova instância do gerenciador.
 */
- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;

/**
 * Inicia a conexão WebRTC.
 * Configura WebRTC, conecta ao servidor de sinalização e inicia a negociação.
 */
- (void)startWebRTC;

/**
 * Encerra a conexão WebRTC.
 * Libera todos os recursos e fecha conexões.
 * @param userInitiated Indica se a desconexão foi solicitada pelo usuário
 */
- (void)stopWebRTC:(BOOL)userInitiated;

/**
 * Coleta estatísticas de qualidade da conexão WebRTC.
 * @return Dicionário contendo estatísticas como RTT, perdas de pacotes, etc.
 */
- (NSDictionary *)getConnectionStats;

@end

#endif /* WEBRTCMANAGER_H */
