#import "FloatingWindow.h"
#import <UIKit/UIKit.h>
#import "logger.h"

static FloatingWindow *floatingWindow;

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    writeLog(@"Tweak carregado em SpringBoard");
    
    // Inicializar a janela flutuante no thread principal
    dispatch_async(dispatch_get_main_queue(), ^{
        writeLog(@"Inicializando FloatingWindow");
        
        // Criar janela com tamanho menor para começar
        CGRect windowFrame = CGRectMake(20, 60, 160, 240);
        floatingWindow = [[FloatingWindow alloc] initWithFrame:windowFrame];
        
        // Mostrar a janela
        [floatingWindow show];
        writeLog(@"Janela flutuante exibida");
    });
}

%end

%ctor {
    writeLog(@"Constructor chamado");
}

%dtor {
    writeLog(@"Destructor chamado");
    [floatingWindow hide];
    floatingWindow = nil;
}
