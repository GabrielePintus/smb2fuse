#import "SMBConnection.h"

@implementation SMBConnection

+ (NSString *)generatedUUID
{
    return [NSString stringWithFormat:@"bookmark-%f-%u",
            [[NSDate date] timeIntervalSince1970],
            arc4random()];
}

+ (instancetype)connectionFromDictionary:(NSDictionary *)dictionary
{
    SMBConnection *connection = [[SMBConnection alloc] init];

    if ([dictionary isKindOfClass:[NSDictionary class]]) {
        connection.uuid = [self trimmedStringFromObject:[dictionary objectForKey:@"uuid"]];
        connection.name = [self trimmedStringFromObject:[dictionary objectForKey:@"name"]];
        connection.server = [self trimmedStringFromObject:[dictionary objectForKey:@"server"]];
        connection.share = [self trimmedStringFromObject:[dictionary objectForKey:@"share"]];
        connection.user = [self trimmedStringFromObject:[dictionary objectForKey:@"user"]];
        connection.domain = [self trimmedStringFromObject:[dictionary objectForKey:@"domain"]];
    }

    if ([connection.uuid length] == 0) {
        connection.uuid = [self generatedUUID];
    }

    return connection;
}

- (id)copyWithZone:(NSZone *)zone
{
    SMBConnection *copy = [[[self class] allocWithZone:zone] init];
    copy.uuid = self.uuid;
    copy.name = self.name;
    copy.server = self.server;
    copy.share = self.share;
    copy.user = self.user;
    copy.domain = self.domain;
    copy.mountedPath = self.mountedPath;
    return copy;
}

- (NSDictionary *)dictionaryRepresentation
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];

    [self setDictionary:dictionary value:self.uuid forKey:@"uuid"];
    [self setDictionary:dictionary value:self.name forKey:@"name"];
    [self setDictionary:dictionary value:self.server forKey:@"server"];
    [self setDictionary:dictionary value:self.share forKey:@"share"];
    [self setDictionary:dictionary value:self.user forKey:@"user"];
    [self setDictionary:dictionary value:self.domain forKey:@"domain"];
    return dictionary;
}

- (NSDictionary *)exportRepresentation
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];

    [self setDictionary:dictionary value:self.name forKey:@"name"];
    [self setDictionary:dictionary value:self.server forKey:@"server"];
    [self setDictionary:dictionary value:self.share forKey:@"share"];
    [self setDictionary:dictionary value:self.user forKey:@"user"];
    [self setDictionary:dictionary value:self.domain forKey:@"domain"];
    return dictionary;
}

- (NSString *)displayName
{
    if ([self.name length] > 0) {
        return self.name;
    }
    if ([self.share length] > 0) {
        return self.share;
    }
    if ([self.server length] > 0) {
        return self.server;
    }
    return @"Untitled Connection";
}

- (NSString *)menuTitleWithMounted:(BOOL)mounted
{
    NSString *title = [self displayName];

    if ([self.server length] > 0) {
        title = [NSString stringWithFormat:@"%@ (%@)", title, self.server];
    }
    if (mounted) {
        title = [NSString stringWithFormat:@"• %@ Connected", title];
    }
    return title;
}

- (NSString *)subtitleText
{
    if ([self.share length] > 0) {
        return [NSString stringWithFormat:@"%@  •  %@", self.server ?: @"", self.share];
    }
    return self.server ?: @"";
}

- (NSString *)detailText
{
    NSString *user = [self.user length] > 0 ? self.user : @"Guest";

    if ([self.domain length] > 0) {
        return [NSString stringWithFormat:@"%@  •  %@", user, self.domain];
    }
    return user;
}

- (NSArray *)mountpointCandidates
{
    if ([self.share length] == 0) {
        return [NSArray array];
    }

    return [NSArray arrayWithObjects:
            [@"/Volumes" stringByAppendingPathComponent:self.share],
            [[NSHomeDirectory() stringByAppendingPathComponent:@"Volumes"] stringByAppendingPathComponent:self.share],
            nil];
}

- (NSString *)expectedFSName
{
    if ([self.server length] == 0 || [self.share length] == 0) {
        return @"";
    }

    return [[NSString stringWithFormat:@"//%@/%@", self.server, self.share] lowercaseString];
}

- (BOOL)hasRequiredFields
{
    return ([self.server length] > 0 && [self.share length] > 0);
}

+ (NSString *)trimmedStringFromObject:(id)object
{
    if (![object isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [(NSString *)object stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)setDictionary:(NSMutableDictionary *)dictionary value:(NSString *)value forKey:(NSString *)key
{
    if ([value length] > 0) {
        [dictionary setObject:value forKey:key];
    }
}

@end
