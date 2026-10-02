#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

static NSString *safeValue(id obj, NSString *key) {
    @try {
        id v = [obj valueForKey:key];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

static void showReply(NSString *msg) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFUserNotificationDisplayNotice(
            3.0, kCFUserNotificationNoteAlertLevel, NULL, NULL, NULL,
            CFSTR("Maltego AI"), (__bridge CFStringRef)msg, CFSTR("OK"));
    });
}

static id callIfExists(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (target && [target respondsToSelector:sel]) {
        return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    }
    return nil;
}

static BOOL callBool(id target, NSString *selName, BOOL arg) {
    SEL sel = NSSelectorFromString(selName);
    if (target && [target respondsToSelector:sel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, arg);
        return YES;
    }
    return NO;
}

static void doRespring(void) {
    id fbs = callIfExists(NSClassFromString(@"FBSystemService"), @"sharedInstance");
    if (callBool(fbs, @"exitAndRelaunch:", YES)) return;
    id app = [UIApplication sharedApplication];
    callIfExists(app, @"_relaunchSpringBoardNow");
}

static BOOL doPower(BOOL reboot) {
    id fbs = callIfExists(NSClassFromString(@"FBSystemService"), @"sharedInstance");
    return callBool(fbs, @"shutdownAndReboot:", reboot);
}

static NSString *aliasFor(NSString *name) {
    NSDictionary *a = @{
        @"телеграм": @"telegram", @"телега": @"telegram",
        @"ютуб": @"youtube", @"инстаграм": @"instagram",
        @"ватсап": @"whatsapp", @"вотсап": @"whatsapp",
        @"тикток": @"tiktok", @"вайбер": @"viber",
        @"сафари": @"safari", @"камера": @"camera",
        @"настройки": @"settings", @"почта": @"mail",
        @"карты": @"maps", @"заметки": @"notes"
    };
    return a[name] ?: name;
}

static BOOL openAppNamed(NSString *query) {
    query = aliasFor(query);
    Class W = NSClassFromString(@"LSApplicationWorkspace");
    id ws = callIfExists(W, @"defaultWorkspace");
    NSArray *apps = callIfExists(ws, @"allInstalledApplications");
    if (!ws || ![apps isKindOfClass:[NSArray class]]) return NO;

    NSString *exactID = nil, *partialID = nil;
    for (id p in apps) {
        NSString *n = [safeValue(p, @"localizedName") lowercaseString];
        NSString *b = safeValue(p, @"applicationIdentifier");
        if (!b) b = safeValue(p, @"bundleIdentifier");
        if (!n || !b) continue;
        if ([n isEqualToString:query]) { exactID = b; break; }
        if (!partialID && ([n containsString:query] || [query containsString:n])) partialID = b;
    }
    NSString *bid = exactID ?: partialID;
    if (!bid) return NO;
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![ws respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid);
}

static void handleCommand(NSString *raw) {
    NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@" \n\t,.:;!?-—"];
    NSString *t = [[raw lowercaseString] stringByTrimmingCharactersInSet:junk];

    NSString *rest = nil;
    for (NSString *w in @[@"maltego", @"мальтего", @"малтего"]) {
        if ([t hasPrefix:w]) { rest = [[t substringFromIndex:w.length] stringByTrimmingCharactersInSet:junk]; break; }
    }
    if (!rest) return; // нет слова Maltego: молчим и ничего не делаем

    if ([rest containsString:@"респринг"] || [rest containsString:@"respring"]) {
        showReply(@"Делаю респринг");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ doRespring(); });
        return;
    }
    if ([rest containsString:@"перезагруз"] || [rest containsString:@"reboot"] || [rest containsString:@"restart"]) {
        showReply(@"Перезагружаю телефон");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!doPower(YES)) showReply(@"Не получилось перезагрузить");
        });
        return;
    }
    if ([rest hasPrefix:@"выключи"] || [rest containsString:@"shutdown"] || [rest containsString:@"power off"]) {
        showReply(@"Выключаю телефон");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!doPower(NO)) showReply(@"Не получилось выключить");
        });
        return;
    }
    for (NSString *p in @[@"открой ", @"зайди в ", @"запусти ", @"open "]) {
        if ([rest hasPrefix:p]) {
            NSString *name = [[rest substringFromIndex:p.length] stringByTrimmingCharactersInSet:junk];
            if (openAppNamed(name)) showReply([NSString stringWithFormat:@"Открываю: %@", name]);
            else showReply([NSString stringWithFormat:@"Не нашёл приложение: %@", name]);
            return;
        }
    }
    showReply(@"Не понял команду");
}

static void showCommandBox(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *d = @{
            (__bridge NSString *)kCFUserNotificationAlertHeaderKey: @"Maltego AI",
            (__bridge NSString *)kCFUserNotificationAlertMessageKey: @"Напиши команду, например: Maltego открой Telegram",
            (__bridge NSString *)kCFUserNotificationTextFieldTitlesKey: @[@""],
            (__bridge NSString *)kCFUserNotificationDefaultButtonTitleKey: @"Выполнить",
            (__bridge NSString *)kCFUserNotificationAlternateButtonTitleKey: @"Отмена"
        };
        SInt32 err = 0;
        CFUserNotificationRef n = CFUserNotificationCreate(
            kCFAllocatorDefault, 0, kCFUserNotificationPlainAlertLevel, &err,
            (__bridge CFDictionaryRef)d);
        if (!n || err) return;
        CFOptionFlags resp = 0;
        CFUserNotificationReceiveResponse(n, 0, &resp);
        if ((resp & 0x3) == kCFUserNotificationDefaultResponse) {
            CFStringRef v = CFUserNotificationGetResponseValue(n, kCFUserNotificationTextFieldValuesKey, 0);
            NSString *text = v ? [(__bridge NSString *)v copy] : @"";
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(text); });
        }
        CFRelease(n);
    });
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showReply(@"Maltego AI готов. Коснись экрана четырьмя пальцами.");
    });
}

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches && [[event allTouches] count] >= 4) {
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 3.0) {
            last = now;
            showCommandBox();
        }
    }
}
%end
