@implementation BurladorManager

+ (instancetype)sharedInstance {
    static BurladorManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isActive = NO;
    }
    return self;
}

- (void)toggleState {
    [self setState:!_isActive];
}

- (void)setState:(BOOL)active {
    if (_isActive != active) {
        _isActive = active;
        
        writeLog(@"[BurladorManager] Estado alterado para: %@", active ? @"ATIVO" : @"INATIVO");
        
        // Notificar callback se existir
        if (self.stateChangeCallback) {
            self.stateChangeCallback(active);
        }
        
        // Postar notificação para garantir que todos os componentes saibam
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BurladorStateChanged"
                                                            object:self
                                                          userInfo:@{@"isActive": @(active)}];
    }
}

@end
