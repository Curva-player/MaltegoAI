#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <notify.h>

#define DIR_PATH @"/var/mobile/Library/MaltegoAI"
#define CONFIG_PATH @"/var/mobile/Library/MaltegoAI/config.plist"
#define INBOX_PATH @"/var/mobile/Library/MaltegoAI/inbox.json"
#define OUTBOX_PATH @"/var/mobile/Library/MaltegoAI/outbox.txt"

#pragma mark - Настройки

static NSMutableDictionary *loadCfg(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:CONFIG_PATH];
    return d ?: [NSMutableDictionary dictionary];
}

static void saveCfg(NSString *key, NSString *value) {
    [[NSFileManager defaultManager] createDirectoryAtPath:DIR_PATH
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = loadCfg();
    d[key] = value ?: @"";
    [d writeToFile:CONFIG_PATH atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600}
                                     ofItemAtPath:CONFIG_PATH error:nil];
}

static NSArray *langs(void) {
    return @[@[@"ru-RU", @"Русский"], @[@"uk-UA", @"Українська"], @[@"en-US", @"English"],
             @[@"de-DE", @"Deutsch"], @[@"fr-FR", @"Français"]];
}

static NSString *langName(NSString *code) {
    for (NSArray *l in langs()) if ([l[0] isEqualToString:code]) return l[1];
    return code;
}

static NSArray *wakeWords(void) {
    return @[@"maltego", @"мальтего", @"малтего", @"мальтиго", @"maltiego", @"maltigo", @"мальтейго"];
}

static NSString *fullLang(NSString *code) {
    NSDictionary *m = @{@"ru": @"ru-RU", @"uk": @"uk-UA", @"en": @"en-US", @"de": @"de-DE", @"fr": @"fr-FR"};
    return m[code];
}

#pragma mark - Движок голоса

@interface Engine : NSObject <AVSpeechSynthesizerDelegate>
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) SFSpeechRecognizer *rec;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *req;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) NSTimer *restartTimer;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) AVSpeechSynthesizer *tts;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL wakeHeard;
@property (nonatomic, copy) NSString *pending;
@property (nonatomic, strong) NSDate *lastChange;
@property (nonatomic, copy) void (^onLog)(NSString *);
+ (instancetype)shared;
- (void)start;
- (void)stop;
- (void)begin;
- (void)speak:(NSString *)text;
@end

@implementation Engine

+ (instancetype)shared {
    static Engine *e;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ e = [Engine new]; });
    return e;
}

- (instancetype)init {
    self = [super init];
    _engine = [AVAudioEngine new];
    _tts = [AVSpeechSynthesizer new];
    _tts.delegate = self;
    _pending = @"";

    int tok;
    notify_register_dispatch("com.curvaplayer.maltegoai.reply", &tok, dispatch_get_main_queue(), ^(int t) {
        NSString *s = [NSString stringWithContentsOfFile:OUTBOX_PATH encoding:NSUTF8StringEncoding error:nil];
        if (s.length) [self speak:s];
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeEnded && self.running) {
            [self setupSession];
            [self begin];
        }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        if (self.running) [self begin];
    }];
    return self;
}

- (void)log:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onLog) self.onLog(s);
    });
}

- (void)setupSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *e = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
       withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                   AVAudioSessionCategoryOptionAllowBluetooth |
                   AVAudioSessionCategoryOptionMixWithOthers
             error:&e];
    [s setActive:YES error:&e];
    if (e) [self log:[NSString stringWithFormat:@"Аудио: %@", e.localizedDescription]];
}

- (void)start {
    if (self.running) return;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [self log:@"Нет разрешения на распознавание речи"];
                return;
            }
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { [self log:@"Нет разрешения на микрофон"]; return; }
                    if (self.running) return;
                    self.running = YES;
                    [self setupSession];
                    [self begin];
                    [self.tickTimer invalidate];
                    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self
                                                                    selector:@selector(tick)
                                                                    userInfo:nil repeats:YES];
                });
            }];
        });
    }];
}

- (void)stop {
    self.running = NO;
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [self endTask];
    [self.engine.inputNode removeTapOnBus:0];
    [self.engine stop];
    [self log:@"Прослушивание выключено"];
}

- (void)endTask {
    [self.restartTimer invalidate];
    self.restartTimer = nil;
    [self.req endAudio];
    self.req = nil;
    [self.task cancel];
    self.task = nil;
}

- (void)begin {
    if (!self.running) return;
    [self endTask];
    self.wakeHeard = NO;
    self.pending = @"";
    __weak Engine *w = self;

    NSString *lang = loadCfg()[@"lang"] ?: @"ru-RU";
    self.rec = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:lang]];
    if (!self.rec || !self.rec.isAvailable) {
        [self log:@"Распознавание речи сейчас недоступно, повторю через 5 с"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (w.running) [w begin];
        });
        return;
    }
    SFSpeechAudioBufferRecognitionRequest *req = [SFSpeechAudioBufferRecognitionRequest new];
    req.shouldReportPartialResults = YES;
    if (self.rec.supportsOnDeviceRecognition) req.requiresOnDeviceRecognition = YES;
    self.req = req;

    AVAudioInputNode *input = self.engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    [input removeTapOnBus:0];
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) {
        [req appendAudioPCMBuffer:buf];
    }];
    if (!self.engine.isRunning) {
        [self.engine prepare];
        NSError *e = nil;
        if (![self.engine startAndReturnError:&e]) {
            [self log:[NSString stringWithFormat:@"Микрофон: %@", e.localizedDescription]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (w.running) [w begin];
            });
            return;
        }
        [self log:[NSString stringWithFormat:@"Слушаю слово Maltego (%@)%@", langName(lang),
                   self.rec.supportsOnDeviceRecognition ? @", на устройстве" : @", через серверы Apple"]];
    }

    self.task = [self.rec recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ [w handle:r error:err request:req]; });
    }];

    self.restartTimer = [NSTimer scheduledTimerWithTimeInterval:45 repeats:NO block:^(NSTimer *t) {
        if (w.wakeHeard) return;
        [w begin];
    }];
}

- (void)handle:(SFSpeechRecognitionResult *)r error:(NSError *)err request:(SFSpeechAudioBufferRecognitionRequest *)req {
    if (!self.running || req != self.req) return;
    __weak Engine *w = self;
    if (!r) {
        if (err && err.code != 1110 && err.code != 203 && err.code != 216) {
            [self log:[NSString stringWithFormat:@"Ошибка распознавания: %@", err.localizedDescription]];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (w.running) [w begin];
        });
        return;
    }
    if (self.tts.isSpeaking) return;

    NSString *text = r.bestTranscription.formattedString;
    NSRange best = NSMakeRange(NSNotFound, 0);
    for (NSString *wk in wakeWords()) {
        NSRange rg = [text rangeOfString:wk options:NSBackwardsSearch | NSCaseInsensitiveSearch];
        if (rg.location != NSNotFound && (best.location == NSNotFound || rg.location > best.location)) best = rg;
    }
    if (best.location != NSNotFound) {
        NSCharacterSet *junk = [NSCharacterSet characterSetWithCharactersInString:@" ,.:;!?-—\n"];
        NSString *tail = [[text substringFromIndex:NSMaxRange(best)] stringByTrimmingCharactersInSet:junk];
        if (!self.wakeHeard) {
            self.wakeHeard = YES;
            self.lastChange = [NSDate date];
            [self log:@"Услышал слово активации"];
        }
        if (![tail isEqualToString:self.pending]) {
            self.pending = tail;
            self.lastChange = [NSDate date];
        }
        if (r.isFinal) [self fire];
    } else if (r.isFinal) {
        [self begin];
    }
}

- (void)tick {
    if (!self.running || !self.wakeHeard || self.tts.isSpeaking) return;
    NSTimeInterval idle = -[self.lastChange timeIntervalSinceNow];
    if ((self.pending.length > 0 && idle > 1.4) || (self.pending.length == 0 && idle > 4.0)) [self fire];
}

- (void)fire {
    NSString *cmd = self.pending ?: @"";
    self.wakeHeard = NO;
    [self log:[NSString stringWithFormat:@"Команда: %@", cmd.length ? cmd : @"(пусто)"]];
    NSDictionary *d = @{@"text": [@"Maltego " stringByAppendingString:cmd],
                        @"voice": @YES,
                        @"id": [[NSUUID UUID] UUIDString]};
    [[NSFileManager defaultManager] createDirectoryAtPath:DIR_PATH
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:d options:0 error:nil] writeToFile:INBOX_PATH atomically:YES];
    notify_post("com.curvaplayer.maltegoai.cmd");
    [self begin];
}

- (void)speak:(NSString *)text {
    NSDictionary *cfg = loadCfg();
    NSString *lang = cfg[@"lang"] ?: @"ru-RU";
    NSString *dl = [NLLanguageRecognizer dominantLanguageForString:text];
    NSString *target = dl ? fullLang(dl) : nil;
    if (!target) target = lang;
    AVSpeechSynthesisVoice *v = nil;
    NSString *vid = cfg[@"voice"];
    if ([target isEqualToString:lang] && vid.length) v = [AVSpeechSynthesisVoice voiceWithIdentifier:vid];
    if (!v) v = [AVSpeechSynthesisVoice voiceWithLanguage:target];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = v;
    [self log:[NSString stringWithFormat:@"Отвечаю: %@", text]];
    [self.tts speakUtterance:u];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u {
    if (self.running) [self begin];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u {
    if (self.running) [self begin];
}

@end

#pragma mark - Экран настроек

@interface VC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *langBtn;
@property (nonatomic, strong) UIButton *voiceBtn;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UISwitch *sw;
@end

@implementation VC

- (UIButton *)button:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.titleLabel.font = [UIFont systemFontOfSize:17];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)label:(NSString *)t bold:(BOOL)bold {
    UILabel *l = [UILabel new];
    l.text = t;
    l.numberOfLines = 0;
    l.font = bold ? [UIFont boldSystemFontOfSize:26] : [UIFont systemFontOfSize:15];
    if (!bold) l.textColor = [UIColor secondaryLabelColor];
    return l;
}

- (UITextField *)field:(NSString *)ph secure:(BOOL)secure {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.secureTextEntry = secure;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.delegate = self;
    return f;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sc.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:sc];

    UIStackView *st = [UIStackView new];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 14;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [sc addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor constant:50],
        [st.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor constant:-30],
        [st.leadingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.leadingAnchor constant:20],
        [st.trailingAnchor constraintEqualToAnchor:sc.frameLayoutGuide.trailingAnchor constant:-20]
    ]];

    NSDictionary *cfg = loadCfg();

    [st addArrangedSubview:[self label:@"Maltego AI" bold:YES]];

    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    UILabel *rl = [UILabel new];
    rl.text = @"Слушать слово «Maltego»";
    self.sw = [UISwitch new];
    self.sw.on = [cfg[@"listening"] isEqualToString:@"1"];
    [self.sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:rl];
    [row addArrangedSubview:self.sw];
    [st addArrangedSubview:row];

    self.langBtn = [self button:@"" action:@selector(pickLang)];
    self.voiceBtn = [self button:@"" action:@selector(pickVoice)];
    [st addArrangedSubview:self.langBtn];
    [st addArrangedSubview:self.voiceBtn];

    [st addArrangedSubview:[self label:@"Как к тебе обращаться" bold:NO]];
    self.nameField = [self field:@"Имя" secure:NO];
    self.nameField.text = cfg[@"name"];
    [st addArrangedSubview:self.nameField];

    [st addArrangedSubview:[self label:@"API-ключ Groq (хранится только на телефоне)" bold:NO]];
    self.keyField = [self field:@"gsk_..." secure:YES];
    [st addArrangedSubview:self.keyField];
    [st addArrangedSubview:[self button:@"Сохранить ключ" action:@selector(saveKey)]];

    [st addArrangedSubview:[self button:@"Проверить голос" action:@selector(testVoice)]];

    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.font = [UIFont systemFontOfSize:13];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.text = @"Журнал";
    [self.logView.heightAnchor constraintEqualToConstant:220].active = YES;
    [st addArrangedSubview:self.logView];

    __weak VC *w = self;
    [Engine shared].onLog = ^(NSString *s) {
        NSString *old = w.logView.text ?: @"";
        NSString *n = [NSString stringWithFormat:@"%@\n%@", s, old];
        if (n.length > 2500) n = [n substringToIndex:2500];
        w.logView.text = n;
    };
    [self refreshTitles];
}

- (void)refreshTitles {
    NSDictionary *cfg = loadCfg();
    NSString *lang = cfg[@"lang"] ?: @"ru-RU";
    [self.langBtn setTitle:[NSString stringWithFormat:@"Язык: %@", langName(lang)] forState:UIControlStateNormal];
    NSString *vid = cfg[@"voice"];
    NSString *vname = @"по умолчанию";
    if (vid.length) {
        AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:vid];
        if (v) vname = v.name;
    }
    [self.voiceBtn setTitle:[NSString stringWithFormat:@"Голос: %@", vname] forState:UIControlStateNormal];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Maltego AI" message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)toggle:(UISwitch *)s {
    saveCfg(@"listening", s.on ? @"1" : @"0");
    if (s.on) [[Engine shared] start]; else [[Engine shared] stop];
}

- (void)pickLang {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Язык" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *l in langs()) {
        [a addAction:[UIAlertAction actionWithTitle:l[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            saveCfg(@"lang", l[0]);
            saveCfg(@"voice", @"");
            [self refreshTitles];
            if ([Engine shared].running) [[Engine shared] begin];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickVoice {
    NSString *lang = loadCfg()[@"lang"] ?: @"ru-RU";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Голос" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"По умолчанию" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        saveCfg(@"voice", @"");
        [self refreshTitles];
    }]];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if (![v.language isEqualToString:lang]) continue;
        NSString *t = v.quality == AVSpeechSynthesisVoiceQualityEnhanced
            ? [NSString stringWithFormat:@"%@ (улучшенный)", v.name] : v.name;
        [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            saveCfg(@"voice", v.identifier);
            [self refreshTitles];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)saveKey {
    NSString *k = [self.keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (k.length < 10) { [self alert:@"Ключ слишком короткий"]; return; }
    saveCfg(@"groq_key", k);
    self.keyField.text = @"";
    [self.view endEditing:YES];
    [self alert:@"Ключ сохранён"];
}

- (void)testVoice {
    NSString *lang = loadCfg()[@"lang"] ?: @"ru-RU";
    NSDictionary *p = @{
        @"ru-RU": @"Привет, я Maltego. Слушаю тебя.",
        @"uk-UA": @"Привіт, я Maltego. Слухаю тебе.",
        @"en-US": @"Hi, I am Maltego. I am listening.",
        @"de-DE": @"Hallo, ich bin Maltego. Ich höre zu.",
        @"fr-FR": @"Salut, je suis Maltego. Je t'écoute."
    };
    [[Engine shared] speak:p[lang] ?: p[@"ru-RU"]];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf == self.nameField) saveCfg(@"name", tf.text ?: @"");
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end

#pragma mark - Запуск

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [VC new];
    [self.window makeKeyAndVisible];
    if ([loadCfg()[@"listening"] isEqualToString:@"1"]) [[Engine shared] start];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
