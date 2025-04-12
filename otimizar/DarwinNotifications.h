#ifndef DARWIN_NOTIFICATIONS_H
#define DARWIN_NOTIFICATIONS_H

#include <notify.h>

// Nome da notificação para estado do burlador
#define NOTIFICATION_BURLADOR_ACTIVATION "com.example.webrtctweak.burlador"

#ifdef __cplusplus
extern "C" {
#endif

// Funções para registrar e verificar estado
void registerBurladorActive(BOOL isActive);
BOOL isBurladorActive(void);

#ifdef __cplusplus
}
#endif

#endif /* DARWIN_NOTIFICATIONS_H */
