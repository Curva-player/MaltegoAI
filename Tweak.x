#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

#define STORE_DIR @"/var/mobile/Library/MaltegoAI"
#define ALIAS_FILE @"/var/mobile/Library/MaltegoAI/aliases.plist"

#pragma mark - Утилиты

static NSString *safeValue(id obj, NSString *key) {
    @try {
        id v = [obj valueForKey:key];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *trim(NSString *s) {
    NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@" \n\t,.:;!?-—"];
    return [s stringByTrimmingCharactersInSet:junk];
}

static void showReply(NSString *msg) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CFUserNotificationDisplayNotice(
            4.0, kCFUserNotificationNoteAlertLevel, NULL, NULL, NULL,
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

#pragma mark - Питание

static void doRespring(void) {
    id fbs = callIfExists(NSClassFromString(@"FBSystemService"), @"sharedInstance");
    if (callBool(fbs, @"exitAndRelaunch:", YES)) return;
    callIfExists([UIApplication sharedApplication], @"_relaunchSpringBoardNow");
}

static BOOL doPower(BOOL reboot) {
    id fbs = callIfExists(NSClassFromString(@"FBSystemService"), @"sharedInstance");
    return callBool(fbs, @"shutdownAndReboot:", reboot);
}

#pragma mark - Память (чему твик научился)

static NSMutableDictionary *loadAliases(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:ALIAS_FILE];
    return d ?: [NSMutableDictionary dictionary];
}

static void saveAlias(NSString *key, NSString *bundleID) {
    if (key.length == 0 || bundleID.length == 0) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:STORE_DIR
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = loadAliases();
    d[key] = bundleID;
    [d writeToFile:ALIAS_FILE atomically:YES];
}

#pragma mark - Поиск приложений

static NSString *norm(NSString *s) {
    NSMutableString *m = [[s lowercaseString] mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformToLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripCombiningMarks, false);
    NSString *t = [m lowercaseString];
    NSMutableString *o = [NSMutableString string];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if ([alnum characterIsMember:c]) [o appendFormat:@"%C", c];
    }
    return o;
}

static NSDictionary *expansions(void) {
    NSArray *tg = @[@"telegram", @"telegra", @"swiftgram", @"nicegram", @"turbogram", @"ayugram"];
    return @{
        @"tg": tg, @"telega": tg, @"telegram": tg, @"telegramm": tg,
        @"utub": @[@"youtube"], @"iutub": @[@"youtube"],
        @"vatsap": @[@"whatsapp"], @"votsap": @[@"whatsapp"], @"vatsapp": @[@"whatsapp"],
        @"insta": @[@"instagram"], @"instagram": @[@"instagram"],
        @"tiktok": @[@"tiktok"], @"tiktok": @[@"tiktok"],
        @"vaiber": @[@"viber"],
        @"kamera": @[@"camera"], @"pocta": @[@"mail"], @"pochta": @[@"mail"],
        @"karty": @[@"maps"], @"zametki": @[@"notes"], @"nastroiki": @[@"settings", @"preferences"]
    };
}

static NSArray *installedApps(void) {
    id ws = callIfExists(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    NSArray *apps = callIfExists(ws, @"allInstalledApplications");
    NSMutableArray *out = [NSMutableArray array];
    if (![apps isKindOfClass:[NSArray class]]) return out;
    for (id p in apps) {
        NSString *n = safeValue(p, @"localizedName");
        NSString *b = safeValue(p, @"applicationIdentifier");
        if (!b) b = safeValue(p, @"bundleIdentifier");
        if (n.length && b.length) [out addObject:@{@"name": n, @"id": b}];
    }
    return out;
}

static BOOL openBundleID(NSString *bid) {
    id ws = callIfExists(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!ws || ![ws respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, sel, bid);
}

static NSArray *rankApps(NSString *query, NSArray *apps) {
    NSString *nq = norm(query);
    if (nq.length < 2) return @[];
    NSMutableArray *keys = [NSMutableArray arrayWithObject:nq];
    NSArray *ex = expansions()[nq];
    if (ex) [keys addObjectsFromArray:ex];

    NSMutableArray *res = [NSMutableArray array];
    for (NSDictionary *a in apps) {
        NSString *n = norm(a[@"name"]);
        NSString *b = [a[@"id"] lowercaseString];
        int best = 0;
        for (NSString *k in keys) {
            int s = 0;
            if ([n isEqualToString:k]) s = 100;
            else if ([n hasPrefix:k]) s = 80;
            else if (k.length >= 3 && [n containsString:k]) s = 70;
            else if (k.length >= 4 && [b containsString:k]) s = 50;
            else if (n.length >= 4 && [k containsString:n]) s = 40;
            if (s > best) best = s;
        }
        if (best >= 40) {
            [res addObject:@{@"name": a[@"name"], @"id": a[@"id"], @"score": @(best)}];
        }
    }
    [res sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        int sx = [x[@"score"] intValue], sy = [y[@"score"] intValue];
        if (sx != sy) return sx > sy ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger lx = [x[@"name"] length], ly = [y[@"name"] length];
        if (lx != ly) return lx < ly ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return res;
}

#pragma mark - Окошко ввода

static void askText(NSString *message, NSString *okTitle, void (^done)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *d = @{
            (__bridge NSString *)kCFUserNotificationAlertHeaderKey: @"Maltego AI",
            (__bridge NSString *)kCFUserNotificationAlertMessageKey: message,
            (__bridge NSString *)kCFUserNotificationTextFieldTitlesKey: @[@""],
            (__bridge NSString *)kCFUserNotificationDefaultButtonTitleKey: okTitle,
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
            dispatch_async(dispatch_get_main_queue(), ^{ done(text); });
        }
        CFRelease(n);
    });
}

#pragma mark - Команды

static void openByName(NSString *name) {
    NSString *nq = norm(name);
    if (nq.length == 0) { showReply(@"Какое приложение открыть?"); return; }
    NSArray *apps = installedApps();

    NSString *learned = loadAliases()[nq];
    if (learned) {
        for (NSDictionary *a in apps) {
            if ([a[@"id"] isEqualToString:learned] && openBundleID(learned)) {
                showReply([NSString stringWithFormat:@"Открываю: %@", a[@"name"]]);
                return;
            }
        }
    }

    NSArray *res = rankApps(name, apps);
    if (res.count > 0) {
        NSDictionary *top = res[0];
        if (openBundleID(top[@"id"])) {
            if ([top[@"score"] intValue] >= 70) saveAlias(nq, top[@"id"]);
            showReply([NSString stringWithFormat:@"Открываю: %@", top[@"name"]]);
            return;
        }
    }

    NSString *q = [NSString stringWithFormat:
        @"Не нашёл «%@» (просмотрено приложений: %lu). Как оно называется на экране?",
        name, (unsigned long)apps.count];
    askText(q, @"Найти", ^(NSString *answer) {
        NSArray *r2 = rankApps(answer, installedApps());
        if (r2.count > 0 && openBundleID(r2[0][@"id"])) {
            saveAlias(nq, r2[0][@"id"]);
            showReply([NSString stringWithFormat:@"Открываю: %@. Запомнил: %@", r2[0][@"name"], name]);
        } else {
            showReply(@"Всё равно не нашёл");
        }
    });
}

static void teach(NSString *left, NSString *right) {
    NSString *nl = norm(left);
    NSArray *res = rankApps(right, installedApps());
    if (nl.length == 0 || res.count == 0) {
        showReply([NSString stringWithFormat:@"Не нашёл приложение: %@", right]);
        return;
    }
    saveAlias(nl, res[0][@"id"]);
    showReply([NSString stringWithFormat:@"Запомнил: %@ → %@", left, res[0][@"name"]]);
}

static void handleCommand(NSString *raw) {
    NSString *t = trim([raw lowercaseString]);

    NSString *rest = nil;
    for (NSString *w in @[@"maltego", @"мальтего", @"малтего"]) {
        if ([t hasPrefix:w]) { rest = trim([t substringFromIndex:w.length]); break; }
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
    if ([rest hasPrefix:@"забудь"]) {
        [[NSFileManager defaultManager] removeItemAtPath:ALIAS_FILE error:nil];
        showReply(@"Забыл всё, чему учился");
        return;
    }
    if ([rest hasPrefix:@"запомни "] || [rest hasPrefix:@"remember "]) {
        NSString *body = [rest substringFromIndex:[rest rangeOfString:@" "].location + 1];
        for (NSString *sep in @[@"=", @" это ", @" - ", @" — "]) {
            NSRange r = [body rangeOfString:sep];
            if (r.location != NSNotFound) {
                teach(trim([body substringToIndex:r.location]),
                      trim([body substringFromIndex:NSMaxRange(r)]));
                return;
            }
        }
        showReply(@"Скажи так: запомни тг = название приложения");
        return;
    }
    for (NSString *p in @[@"открой ", @"зайди в ", @"зайди на ", @"запусти ", @"open "]) {
        if ([rest hasPrefix:p]) {
            openByName(trim([rest substringFromIndex:p.length]));
            return;
        }
    }
    showReply(@"Не понял команду");
}

static void showCommandBox(void) {
    askText(@"Напиши команду, например: Maltego открой тг", @"Выполнить", ^(NSString *text) {
        handleCommand(text);
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
