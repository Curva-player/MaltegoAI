#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

#define STORE_DIR @"/var/mobile/Library/MaltegoAI"
#define ALIAS_FILE @"/var/mobile/Library/MaltegoAI/aliases.plist"
#define CONFIG_FILE @"/var/mobile/Library/MaltegoAI/config.plist"

static NSString *gBrainNote = nil;

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

#pragma mark - Память и настройки

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

static NSMutableDictionary *loadConfig(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:CONFIG_FILE];
    return d ?: [NSMutableDictionary dictionary];
}

static void saveConfigValue(NSString *key, NSString *value) {
    [[NSFileManager defaultManager] createDirectoryAtPath:STORE_DIR
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = loadConfig();
    d[key] = value;
    [d writeToFile:CONFIG_FILE atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:CONFIG_FILE error:nil];
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
        @"tiktok": @[@"tiktok"],
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

#pragma mark - Приложения: открыть и научиться

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

#pragma mark - Очистка кэша

static unsigned long long dirSize(NSString *path) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:path];
    NSString *f;
    while ((f = [e nextObject])) {
        total += [[e fileAttributes] fileSize];
    }
    return total;
}

static long long clearCaches(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *containers = [fm contentsOfDirectoryAtPath:root error:nil];
    if (containers.count == 0) return -1;
    long long freed = 0;
    for (NSString *c in containers) {
        for (NSString *sub in @[@"Library/Caches", @"tmp"]) {
            NSString *dir = [[root stringByAppendingPathComponent:c] stringByAppendingPathComponent:sub];
            NSArray *items = [fm contentsOfDirectoryAtPath:dir error:nil];
            for (NSString *it in items) {
                if ([it isEqualToString:@"Snapshots"] || [it hasPrefix:@"com.apple."]) continue;
                NSString *p = [dir stringByAppendingPathComponent:it];
                BOOL isDir = NO;
                [fm fileExistsAtPath:p isDirectory:&isDir];
                unsigned long long sz = isDir ? dirSize(p) : [[fm attributesOfItemAtPath:p error:nil] fileSize];
                if ([fm removeItemAtPath:p error:nil]) freed += (long long)sz;
            }
        }
    }
    return freed;
}

static void doClear(BOOL thenRespring) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        long long freed = clearCaches();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (freed < 0) { showReply(@"Нет доступа к кэшу приложений"); return; }
            NSString *m = [NSString stringWithFormat:@"Готово. Освобождено: %.1f МБ", freed / 1048576.0];
            if (thenRespring) {
                showReply([m stringByAppendingString:@". Делаю респринг"]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ doRespring(); });
            } else {
                showReply(m);
            }
        });
    });
}

#pragma mark - Выполнение действий

static void runAction(NSString *action, NSString *arg, NSString *say) {
    if ([action isEqualToString:@"open_app"]) {
        openByName(arg);
    } else if ([action isEqualToString:@"respring"]) {
        showReply(say.length ? say : @"Делаю респринг");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ doRespring(); });
    } else if ([action isEqualToString:@"reboot"]) {
        showReply(say.length ? say : @"Перезагружаю телефон");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!doPower(YES)) showReply(@"Не получилось перезагрузить");
        });
    } else if ([action isEqualToString:@"shutdown"]) {
        showReply(say.length ? say : @"Выключаю телефон");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!doPower(NO)) showReply(@"Не получилось выключить");
        });
    } else if ([action isEqualToString:@"clear_cache"]) {
        showReply(say.length ? say : @"Чищу кэш");
        doClear(NO);
    } else if ([action isEqualToString:@"optimize"]) {
        showReply(say.length ? say : @"Оптимизирую телефон");
        doClear(YES);
    } else if ([action isEqualToString:@"set_name"]) {
        if (arg.length) saveConfigValue(@"name", arg);
        showReply(say.length ? say : @"Запомнил имя");
    } else {
        showReply(say.length ? say : @"Не понял команду");
    }
}

#pragma mark - Мозг (Groq)

static NSDictionary *extractJSON(NSString *s) {
    NSRange a = [s rangeOfString:@"{"];
    NSRange b = [s rangeOfString:@"}" options:NSBackwardsSearch];
    if (a.location == NSNotFound || b.location == NSNotFound || b.location < a.location) return nil;
    NSString *sub = [s substringWithRange:NSMakeRange(a.location, b.location - a.location + 1)];
    id o = [NSJSONSerialization JSONObjectWithData:[sub dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : nil;
}

static void askBrain(NSString *userText, void (^ok)(NSDictionary *), void (^fail)(NSString *)) {
    NSDictionary *cfg = loadConfig();
    NSString *key = cfg[@"groq_key"];
    if (key.length == 0) { fail(nil); return; }
    NSString *model = cfg[@"model"] ?: @"llama-3.3-70b-versatile";
    NSString *name = cfg[@"name"] ?: @"unknown";

    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *a in installedApps()) {
        if (![names containsObject:a[@"name"]]) [names addObject:a[@"name"]];
        if (names.count >= 300) break;
    }
    NSString *appsList = [names componentsJoinedByString:@"; "];

    NSString *sys = [NSString stringWithFormat:
        @"You are Maltego, a voice assistant living inside the user's jailbroken iPhone. "
        @"Reply with ONE JSON object and nothing else: "
        @"{\"action\": \"<open_app|respring|reboot|shutdown|clear_cache|optimize|set_name|chat>\", "
        @"\"arg\": \"<string or empty>\", \"say\": \"<short reply in the SAME language as the user's command, max 100 characters>\"}. "
        @"Rules: open_app: arg = the exact app name taken from the INSTALLED APPS list below "
        @"(understand nicknames, abbreviations and other languages, for example a short word for Telegram means the Telegram app in the list). "
        @"If no app fits, use chat and say you could not find it. "
        @"respring = restart the UI, reboot = restart the phone, shutdown = power off, "
        @"clear_cache = delete app caches, optimize = clear caches and refresh the system so the phone runs faster, "
        @"set_name: arg = the name the user wants to be called. "
        @"chat: anything else (questions, small talk, unsupported requests); answer briefly in say. "
        @"Never invent apps. Output only the JSON. The user's name: %@. INSTALLED APPS: %@",
        name, appsList];

    NSDictionary *body = @{
        @"model": model, @"temperature": @0, @"max_tokens": @200,
        @"messages": @[@{@"role": @"system", @"content": sys},
                       @{@"role": @"user", @"content": userText}]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.groq.com/openai/v1/chat/completions"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 12;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = data;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSDictionary *plan = nil;
        NSString *why = nil;
        NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)r statusCode] : 0;
        if (e || !d) {
            why = @"нет сети";
        } else if (code == 401) {
            why = @"ключ не подошёл (401)";
        } else if (code == 429) {
            why = @"лимит запросов (429)";
        } else if (code != 200) {
            why = [NSString stringWithFormat:@"ошибка %ld", (long)code];
        } else {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *content = nil;
            if ([j isKindOfClass:[NSDictionary class]]) {
                NSArray *ch = j[@"choices"];
                if ([ch isKindOfClass:[NSArray class]] && ch.count > 0) {
                    id m = ch[0][@"message"];
                    if ([m isKindOfClass:[NSDictionary class]]) content = m[@"content"];
                }
            }
            if ([content isKindOfClass:[NSString class]]) plan = extractJSON(content);
            if (!plan) why = @"странный ответ нейросети";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (plan) ok(plan); else fail(why);
        });
    }] resume];
}

static void runPlan(NSDictionary *plan) {
    NSString *action = [plan[@"action"] isKindOfClass:[NSString class]] ? plan[@"action"] : @"chat";
    NSString *arg = [plan[@"arg"] isKindOfClass:[NSString class]] ? plan[@"arg"] : @"";
    NSString *say = [plan[@"say"] isKindOfClass:[NSString class]] ? plan[@"say"] : @"";
    runAction(action, arg, say);
}

#pragma mark - Команды без нейросети (запасной вариант)

static void localCommand(NSString *rest) {
    if ([rest containsString:@"респринг"] || [rest containsString:@"respring"]) { runAction(@"respring", @"", @""); return; }
    if ([rest containsString:@"перезагруз"] || [rest containsString:@"reboot"] || [rest containsString:@"restart"]) { runAction(@"reboot", @"", @""); return; }
    if ([rest isEqualToString:@"выключи"] ||
        ([rest hasPrefix:@"выключи"] && ([rest containsString:@"телефон"] || [rest containsString:@"айфон"])) ||
        [rest containsString:@"shutdown"] || [rest containsString:@"power off"]) { runAction(@"shutdown", @"", @""); return; }
    if ([rest containsString:@"оптимиз"] || [rest containsString:@"optimi"]) { runAction(@"optimize", @"", @""); return; }
    if ([rest containsString:@"кэш"] || [rest containsString:@"кеш"] || [rest containsString:@"cache"] ||
        [rest hasPrefix:@"почисти"] || [rest hasPrefix:@"очисти"]) { runAction(@"clear_cache", @"", @""); return; }
    for (NSString *p in @[@"открой ", @"зайди в ", @"зайди на ", @"запусти ", @"open "]) {
        if ([rest hasPrefix:p]) {
            openByName(trim([rest substringFromIndex:p.length]));
            return;
        }
    }
    NSString *note = gBrainNote.length ? [NSString stringWithFormat:@" (%@)", gBrainNote] : @"";
    showReply([@"Не понял команду" stringByAppendingString:note]);
}

#pragma mark - Главный обработчик

static void handleCommand(NSString *raw) {
    NSString *t = trim([raw lowercaseString]);

    NSString *rest = nil;
    for (NSString *w in @[@"maltego", @"мальтего", @"малтего"]) {
        if ([t hasPrefix:w]) { rest = trim([t substringFromIndex:w.length]); break; }
    }
    if (!rest) return; // нет слова Maltego: молчим и ничего не делаем

    if (rest.length == 0) {
        NSString *name = loadConfig()[@"name"];
        showReply(name.length ? [NSString stringWithFormat:@"Слушаю, %@", name] : @"Слушаю");
        return;
    }
    if ([rest hasPrefix:@"ключ"] || [rest hasPrefix:@"key"]) {
        askText(@"Вставь API-ключ Groq (начинается с gsk_)", @"Сохранить", ^(NSString *k) {
            NSString *key = trim(k);
            if (key.length < 10) { showReply(@"Ключ не сохранён: слишком короткий"); return; }
            saveConfigValue(@"groq_key", key);
            showReply(@"Ключ сохранён");
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

    NSString *key = loadConfig()[@"groq_key"];
    if (key.length == 0) {
        localCommand(rest);
        return;
    }
    askBrain(rest, ^(NSDictionary *plan) {
        runPlan(plan);
    }, ^(NSString *why) {
        gBrainNote = why;
        localCommand(rest);
        gBrainNote = nil;
    });
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
