#import "SMBKeychainStore.h"

#import <Security/Security.h>

#ifndef kSecProtocolTypeSMB
#define kSecProtocolTypeSMB ((SecProtocolType)'smb ')
#endif

@implementation SMBKeychainStore

- (NSString *)passwordForServer:(NSString *)server
                           user:(NSString *)user
                         domain:(NSString *)domain
                          found:(BOOL *)found
{
    UInt32 passwordLength = 0;
    void *passwordData = NULL;
    SecKeychainItemRef itemRef = NULL;
    OSStatus status = SecKeychainFindInternetPassword(NULL,
                                                      (UInt32)[server lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [server UTF8String],
                                                      (UInt32)[domain lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [domain length] > 0 ? [domain UTF8String] : NULL,
                                                      (UInt32)[user lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [user UTF8String],
                                                      0,
                                                      NULL,
                                                      0,
                                                      kSecProtocolTypeSMB,
                                                      kSecAuthenticationTypeDefault,
                                                      &passwordLength,
                                                      &passwordData,
                                                      &itemRef);
    NSString *password = nil;

    if (found) {
        *found = (status == errSecSuccess);
    }
    if (status != errSecSuccess) {
        if (itemRef != NULL) {
            CFRelease(itemRef);
        }
        return nil;
    }

    if (passwordLength == 0) {
        password = @"";
    } else {
        password = [[NSString alloc] initWithBytes:passwordData
                                            length:passwordLength
                                          encoding:NSUTF8StringEncoding];
        if (!password) {
            password = [[NSString alloc] initWithData:[NSData dataWithBytes:passwordData length:passwordLength]
                                             encoding:NSISOLatin1StringEncoding];
        }
    }

    if (passwordData != NULL) {
        SecKeychainItemFreeContent(NULL, passwordData);
    }
    if (itemRef != NULL) {
        CFRelease(itemRef);
    }

    return password ?: @"";
}

- (BOOL)hasPasswordForServer:(NSString *)server
                        user:(NSString *)user
                      domain:(NSString *)domain
{
    BOOL found = NO;
    [self passwordForServer:server user:user domain:domain found:&found];
    return found;
}

- (OSStatus)storePassword:(NSString *)password
                   server:(NSString *)server
                     user:(NSString *)user
                   domain:(NSString *)domain
{
    SecKeychainItemRef itemRef = NULL;
    OSStatus status = SecKeychainFindInternetPassword(NULL,
                                                      (UInt32)[server lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [server UTF8String],
                                                      (UInt32)[domain lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [domain length] > 0 ? [domain UTF8String] : NULL,
                                                      (UInt32)[user lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [user UTF8String],
                                                      0,
                                                      NULL,
                                                      0,
                                                      kSecProtocolTypeSMB,
                                                      kSecAuthenticationTypeDefault,
                                                      NULL,
                                                      NULL,
                                                      &itemRef);
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];

    if (status == errSecSuccess && itemRef != NULL) {
        status = SecKeychainItemModifyAttributesAndData(itemRef,
                                                        NULL,
                                                        (UInt32)[passwordData length],
                                                        [passwordData bytes]);
        CFRelease(itemRef);
        return status;
    }

    if (status != errSecItemNotFound) {
        if (itemRef != NULL) {
            CFRelease(itemRef);
        }
        return status;
    }

    return SecKeychainAddInternetPassword(NULL,
                                          (UInt32)[server lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                          [server UTF8String],
                                          (UInt32)[domain lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                          [domain length] > 0 ? [domain UTF8String] : NULL,
                                          (UInt32)[user lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                          [user UTF8String],
                                          0,
                                          NULL,
                                          0,
                                          kSecProtocolTypeSMB,
                                          kSecAuthenticationTypeDefault,
                                          (UInt32)[passwordData length],
                                          [passwordData bytes],
                                          NULL);
}

- (OSStatus)deletePasswordForServer:(NSString *)server
                               user:(NSString *)user
                             domain:(NSString *)domain
{
    SecKeychainItemRef itemRef = NULL;
    OSStatus status = SecKeychainFindInternetPassword(NULL,
                                                      (UInt32)[server lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [server UTF8String],
                                                      (UInt32)[domain lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [domain length] > 0 ? [domain UTF8String] : NULL,
                                                      (UInt32)[user lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                                                      [user UTF8String],
                                                      0,
                                                      NULL,
                                                      0,
                                                      kSecProtocolTypeSMB,
                                                      kSecAuthenticationTypeDefault,
                                                      NULL,
                                                      NULL,
                                                      &itemRef);

    if (status != errSecSuccess) {
        if (itemRef != NULL) {
            CFRelease(itemRef);
        }
        return status;
    }

    status = SecKeychainItemDelete(itemRef);
    CFRelease(itemRef);
    return status;
}

- (NSString *)errorStringForStatus:(OSStatus)status
{
    CFStringRef message = SecCopyErrorMessageString(status, NULL);
    NSString *string = nil;

    if (message != NULL) {
        string = CFBridgingRelease(message);
    }
    if ([string length] == 0) {
        string = [NSString stringWithFormat:@"Security error %d", (int)status];
    }
    return string;
}

@end
