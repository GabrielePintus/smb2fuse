#import <Foundation/Foundation.h>
#import <Security/Security.h>

@interface SMBKeychainStore : NSObject

- (NSString *)passwordForServer:(NSString *)server
                           user:(NSString *)user
                         domain:(NSString *)domain
                          found:(BOOL *)found;

- (BOOL)hasPasswordForServer:(NSString *)server
                        user:(NSString *)user
                      domain:(NSString *)domain;

- (OSStatus)storePassword:(NSString *)password
                   server:(NSString *)server
                     user:(NSString *)user
                   domain:(NSString *)domain;

- (OSStatus)deletePasswordForServer:(NSString *)server
                               user:(NSString *)user
                             domain:(NSString *)domain;

- (NSString *)errorStringForStatus:(OSStatus)status;

@end
