#import <Foundation/Foundation.h>

@interface SMBConnection : NSObject <NSCopying>

@property (copy) NSString *uuid;
@property (copy) NSString *name;
@property (copy) NSString *server;
@property (copy) NSString *share;
@property (copy) NSString *user;
@property (copy) NSString *domain;
@property (copy) NSString *mountedPath;

+ (NSString *)generatedUUID;
+ (instancetype)connectionFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
- (NSDictionary *)exportRepresentation;

- (NSString *)displayName;
- (NSString *)menuTitleWithMounted:(BOOL)mounted;
- (NSString *)subtitleText;
- (NSString *)detailText;
- (NSArray *)mountpointCandidates;
- (NSString *)expectedFSName;
- (BOOL)hasRequiredFields;

@end
