#import <Foundation/Foundation.h>
#import <notify.h>

#define BRIDGE_DIR @"/var/mobile/Library/MaltegoAI"

static void handleCommand(NSString *raw); // реализована в Tweak.x

static double gVoiceUntil = 0;

static BOOL bridgeSpeak(NSString *msg) {
    if ([[NSDate date] timeIntervalSince1970] > gVoiceUntil) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:BRIDGE_DIR
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [msg writeToFile:BRIDGE_DIR @"/outbox.txt" atomically:YES
            encoding:NSUTF8StringEncoding error:nil];
    notify_post("com.curvaplayer.maltegoai.reply");
    return YES;
}

__attribute__((constructor)) static void bridgeInit(void) {
    static int token;
    notify_register_dispatch("com.curvaplayer.maltegoai.cmd", &token,
                             dispatch_get_main_queue(), ^(int t) {
        NSData *d = [NSData dataWithContentsOfFile:BRIDGE_DIR @"/inbox.json"];
        if (!d) return;
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return;
        NSString *text = j[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) return;
        if ([j[@"voice"] boolValue]) {
            gVoiceUntil = [[NSDate date] timeIntervalSince1970] + 25;
        }
        handleCommand(text);
    });
}
