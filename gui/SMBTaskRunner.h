#import <Foundation/Foundation.h>

typedef void (^SMBTaskRunnerCompletion)(int status, NSString *output);

@interface SMBTaskRunner : NSObject

- (void)runCommandAtPath:(NSString *)path
               arguments:(NSArray *)arguments
             stdinString:(NSString *)stdinString
              completion:(SMBTaskRunnerCompletion)completion;

- (NSString *)outputForCommandAtPath:(NSString *)path
                           arguments:(NSArray *)arguments
                   terminationStatus:(int *)terminationStatus;

- (NSString *)outputForCommandAtPath:(NSString *)path
                           arguments:(NSArray *)arguments
                         stdinString:(NSString *)stdinString
                   terminationStatus:(int *)terminationStatus;

@end
