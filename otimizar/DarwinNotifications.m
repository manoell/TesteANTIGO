#import "DarwinNotifications.h"
#import "logger.h"

// Token de registro para a notificação
static int gNotificationToken = 0;

void registerBurladorActive(BOOL isActive) {
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        notify_register_check(NOTIFICATION_BURLADOR_ACTIVATION, &gNotificationToken);
    });
    
    uint64_t state = isActive ? 1 : 0;
    int result = notify_set_state(gNotificationToken, state);
    int postResult = notify_post(NOTIFICATION_BURLADOR_ACTIVATION);
    
    writeLog(@"[Darwin] Registrando estado burlador: %@ (set: %d, post: %d)",
             isActive ? @"ATIVO" : @"INATIVO", result, postResult);
}

BOOL isBurladorActive(void) {
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        notify_register_check(NOTIFICATION_BURLADOR_ACTIVATION, &gNotificationToken);
    });
    
    uint64_t state = 0;
    notify_get_state(gNotificationToken, &state);
    
    return (state == 1);
}
