#ifndef BURLADOR_MANAGER_H
#define BURLADOR_MANAGER_H

#import <Foundation/Foundation.h>

@interface BurladorManager : NSObject

@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, copy) void (^stateChangeCallback)(BOOL isActive);

+ (instancetype)sharedInstance;
- (void)toggleState;
- (void)setState:(BOOL)active;
- (BOOL)isActive;

@end

#endif /* BURLADOR_MANAGER_H */
