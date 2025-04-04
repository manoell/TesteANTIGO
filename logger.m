#import "logger.h"
#import <UIKit/UIKit.h>

static NSString *gLogPath = @"/var/tmp/webrtctweak.log";
static NSLock *gLogLock = nil;

// Inicializar o lock uma única vez
__attribute__((constructor))
static void initialize() {
    if (!gLogLock) {
        gLogLock = [[NSLock alloc] init];
        
        // Adicionar cabeçalho ao log uma vez por execução
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        
        NSString *header = [NSString stringWithFormat:@"\n\n=== NOVA SESSÃO: %@ ===\n",
                           [formatter stringFromDate:[NSDate date]]];
        
        [header writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding
                     error:nil];
    }
}

void writeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // Adicionar timestamp
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    // Imprimir no console
    NSLog(@"%@", message);
    
    // Escrever no arquivo de forma thread-safe
    [gLogLock lock];
    @try {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            // Criar arquivo se não existir
            [logMessage writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding
                             error:nil];
        }
    } @finally {
        [gLogLock unlock];
    }
}

void clearLogFile(void) {
    [gLogLock lock];
    @try {
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"Arquivo de log limpo: %@", gLogPath);
        
        // Adicionar cabeçalho após limpar
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
        
        NSString *header = [NSString stringWithFormat:@"=== LOG REINICIADO: %@ ===\n",
                           [formatter stringFromDate:[NSDate date]]];
        
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        [fileHandle writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } @finally {
        [gLogLock unlock];
    }
}
