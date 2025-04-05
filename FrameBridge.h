#ifndef FRAMEBRIDGE_H
#define FRAMEBRIDGE_H

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebRTC/WebRTC.h>

/**
 * FrameBridge
 *
 * Classe singleton que serve como ponte entre o WebRTCManager e o sistema de substituição de câmera.
 * Recebe frames do WebRTC e os converte para CMSampleBufferRef que pode ser usado pelo sistema iOS.
 */
@interface FrameBridge : NSObject

/**
 * Retorna a instância singleton da FrameBridge
 */
+ (instancetype)sharedInstance;

/**
 * Define se a ponte está ativa (WebRTC recebendo frames)
 */
@property (nonatomic, assign) BOOL isActive;

/**
 * Processa um novo frame de vídeo recebido do WebRTC
 * @param frame O frame de vídeo a ser processado
 */
- (void)processVideoFrame:(RTCVideoFrame *)frame;

/**
 * Obtém o frame atual como um CMSampleBufferRef
 * @param srcBuffer Buffer original que pode conter informações de formato (pode ser nil)
 * @param forceReNew Força a criação de um novo buffer mesmo se o último ainda for válido
 * @return CMSampleBufferRef com o frame atual, ou nil se não houver frame disponível
 */
- (CMSampleBufferRef)getCurrentFrame:(CMSampleBufferRef)srcBuffer forceReNew:(BOOL)forceReNew;

/**
 * Libera recursos quando a ponte não é mais necessária
 */
- (void)releaseResources;

/**
 * Define um callback a ser chamado quando um novo frame estiver disponível
 * @param callback O bloco a ser chamado quando um novo frame estiver disponível
 */
- (void)setNewFrameCallback:(void (^)(void))callback;

@end

#endif /* FRAMEBRIDGE_H */
