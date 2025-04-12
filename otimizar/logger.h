#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Função de log simples
void writeLog(NSString *format, ...);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
