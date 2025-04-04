#import "FloatingWindow.h"
#import "WebRTCManager.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        floatingWindow = [[FloatingWindow alloc] init];
        WebRTCManager *manager = [[WebRTCManager alloc] initWithFloatingWindow:floatingWindow];
        floatingWindow.webRTCManager = manager;
        
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida em modo minimizado");
    });
}

%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    if (floatingWindow) {
        [floatingWindow hide];
    }
    floatingWindow = nil;
}
