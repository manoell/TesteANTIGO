#import "DarwinNotifications.h"
#import "logger.h"

// Registrar o estado do burlador (ativo/inativo) via Darwin Notifications
void registerBurladorActive(BOOL isActive) {
    uint64_t state = isActive ? 1 : 0;
    
    // Registrar a notificação se for a primeira vez
    static dispatch_once_t onceToken;
    static int token = 0;
    
    dispatch_once(&onceToken, ^{
        notify_register_check(NOTIFICATION_BURLADOR_ACTIVATION, &token);
    });
    
    // Definir o estado e postar a notificação
    int result = notify_set_state(token, state);
    int postResult = notify_post(NOTIFICATION_BURLADOR_ACTIVATION);
    
    writeLog(@"[Darwin] Registrando estado burlador: %@ (set: %d, post: %d)",
             isActive ? @"ATIVO" : @"INATIVO", result, postResult);
}

// Verificar se o burlador está ativo
BOOL isBurladorActive(void) {
    // Registrar a notificação se for a primeira vez
    static dispatch_once_t onceToken;
    static int token = 0;
    
    dispatch_once(&onceToken, ^{
        notify_register_check(NOTIFICATION_BURLADOR_ACTIVATION, &token);
    });
    
    // Obter o estado atual
    uint64_t state = 0;
    notify_get_state(token, &state);
    
    return (state == 1);
}
