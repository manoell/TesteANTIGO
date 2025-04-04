#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Uma única função de log simples
void writeLog(NSString *format, ...);

// Função para limpar o arquivo de log
void clearLogFile(void);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
