#import "logger.h"
#import <UIKit/UIKit.h>

static NSString *const kLogPath = @"/var/tmp/webrtctweak.log";
static NSLock *gLogLock = nil;

__attribute__((constructor))
static void initialize() {
    gLogLock = gLogLock ?: [[NSLock alloc] init];
}

void writeLog(NSString *format, ...) {
    // Formatar a mensagem
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
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (fileHandle) {
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [fileHandle closeFile];
        } else {
            [logMessage writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @finally {
        [gLogLock unlock];
    }
}
