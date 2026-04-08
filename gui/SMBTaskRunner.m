#import "SMBTaskRunner.h"

#import <dispatch/dispatch.h>

@implementation SMBTaskRunner

- (void)runCommandAtPath:(NSString *)path
               arguments:(NSArray *)arguments
             stdinString:(NSString *)stdinString
              completion:(SMBTaskRunnerCompletion)completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int status = -1;
        NSString *output = [self outputForCommandAtPath:path
                                              arguments:arguments
                                            stdinString:stdinString
                                      terminationStatus:&status];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(status, output ?: @"");
            }
        });
    });
}

- (NSString *)outputForCommandAtPath:(NSString *)path
                           arguments:(NSArray *)arguments
                   terminationStatus:(int *)terminationStatus
{
    return [self outputForCommandAtPath:path
                              arguments:arguments
                            stdinString:nil
                      terminationStatus:terminationStatus];
}

- (NSString *)outputForCommandAtPath:(NSString *)path
                           arguments:(NSArray *)arguments
                         stdinString:(NSString *)stdinString
                   terminationStatus:(int *)terminationStatus
{
    NSTask *task = nil;
    NSPipe *outputPipe = nil;
    NSPipe *inputPipe = nil;
    NSString *output = @"";

    if (terminationStatus) {
        *terminationStatus = -1;
    }
    if ([path length] == 0) {
        return @"";
    }

    task = [[NSTask alloc] init];
    outputPipe = [NSPipe pipe];
    [task setLaunchPath:path];
    [task setArguments:arguments ?: [NSArray array]];
    [task setStandardOutput:outputPipe];
    [task setStandardError:outputPipe];

    if (stdinString != nil) {
        inputPipe = [NSPipe pipe];
        [task setStandardInput:inputPipe];
    }

    @try {
        [task launch];

        if (inputPipe != nil) {
            NSData *data = [stdinString dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            [[inputPipe fileHandleForWriting] writeData:data];
            [[inputPipe fileHandleForWriting] closeFile];
        }

        output = [self readOutputFromPipe:outputPipe];
        [task waitUntilExit];
        if (terminationStatus) {
            *terminationStatus = [task terminationStatus];
        }
    }
    @catch (NSException *exception) {
        output = [NSString stringWithFormat:@"Failed to launch task: %@\n", [exception reason]];
    }

    return output ?: @"";
}

- (NSString *)readOutputFromPipe:(NSPipe *)pipe
{
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];

    if ([data length] == 0) {
        return @"";
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        return @"<non-UTF8 output>\n";
    }
    return text;
}

@end
