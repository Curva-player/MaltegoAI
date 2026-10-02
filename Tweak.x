#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFUserNotificationDisplayNotice(
            0,
            kCFUserNotificationNoteAlertLevel,
            NULL, NULL, NULL,
            CFSTR("Maltego AI"),
            (__bridge CFStringRef)@"Твик загружен",
            CFSTR("OK"));
    });
}
%end
