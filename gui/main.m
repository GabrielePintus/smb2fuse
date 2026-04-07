#import <Cocoa/Cocoa.h>

#import "SMBAppDelegate.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        (void)argc;
        (void)argv;
        NSApplication *app = [NSApplication sharedApplication];
        SMBAppDelegate *delegate = [[SMBAppDelegate alloc] init];

        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app setDelegate:delegate];
        [app run];
    }

    return 0;
}
