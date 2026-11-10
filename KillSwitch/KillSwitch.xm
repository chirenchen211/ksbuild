// ============================================================================
//  KillSwitch.xm  ——  卡密验证 + 远程开关（验证3.dylib 配套）
//
//  一、卡密验证（走你自己的接口）
//      GET http://123.56.151.179/verify.php?act=verify&key=<卡密>&machine=<设备码>
//      返回 {"code":0,"msg":"验证成功","expire":"...","days":N,"online":M,...}
//      code=0 放行；-2/-3/-4/-5 分别提示 不存在/封禁/到期/换设备
//
//      * 接口是 http + 裸 IP，iOS 的 ATS 会拦 NSURLSession，所以这里用 BSD socket
//        自己发 HTTP/1.0 请求，绕开 ATS，不需要改 App 的 Info.plist。
//
//  二、远程开关（[开关]开[开关] / [开关]关[开关]）
//      主源 GitHub Contents API（国内直连、无 CDN 缓存），备源 jsDelivr / raw。
//      下发「关」→ 弹提示 → 强退 App。
//
//  三、功能和开关都通过 A5 闸门生效：卡密没过 或 开关为关 → 插件功能直接空转。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

// ============================== 卡密接口配置 ==============================

// 你的验证接口（换服务器只改这一行）
#define KS_API_BASE          @"http://123.56.151.179/verify.php"

// 心跳间隔（秒）：既保活，也实时检测 封禁/到期/换设备
#define KS_HEARTBEAT         60.0

// 未授权时用户点「退出」是否强退（1 = 杀；0 = 放行但功能仍空转）
#define KS_KILL_WHEN_UNAUTH  1

#define KS_UD_KEY            @"ks_card_key"
#define KS_UD_MACHINE        @"ks_machine_id"

#define KS_TEXT_ON           @"[开关]开[开关]"
#define KS_TEXT_OFF          @"[开关]关[开关]"

#define KS_GATE_FEATURES     1

// ============================== 远程开关配置 ==============================

static NSArray<NSString *> *KSRemoteURLs(void) {
    return @[
        @"https://api.github.com/repos/chirenchen211/ksbuild/contents/switch.json",
        @"https://cdn.jsdelivr.net/gh/chirenchen211/ksbuild@main/switch.json",
        @"https://raw.githubusercontent.com/chirenchen211/ksbuild/main/switch.json"
    ];
}

#define KS_SECRET            @""
#define KS_CHECK_INTERVAL    90.0
#define KS_WATCHDOG_INTERVAL 5.0
#define KS_FAIL_LIMIT        0
#define KS_CACHE_TTL         0
#define KS_SHOW_ALERT        1
#define KS_KILL_DELAY        1.2
#define KS_LOCAL_FILE        @"/var/mobile/Library/Preferences/com.ks.remote.plist"

// ============================== 全局状态 ==============================

static BOOL      gKSOn        = YES;
static BOOL      gKSStarted   = NO;
static NSInteger gKSFailCount = 0;
static NSString *gKSMessage   = @"";

static BOOL      gAuthOK      = NO;
static NSString *gCardKey     = @"";
static NSString *gCardExpire  = @"";
static NSInteger gCardDays    = 0;
static NSInteger gCardOnline  = 0;
static NSString *gCardNote    = @"";
static NSString *gCardMsg     = @"";
static NSInteger gAuthFail    = 0;
static BOOL      gPrompting   = NO;

static UIAlertController *gKSAlert = nil;

BOOL KSIsEnabled(void);
NSString *KSStatusText(void);
void KSAuthKickOff(void);
void KSInstallOnce(void);

// ============================== 基础工具 ==============================

static UIViewController *KSTopViewController(void) {
    UIWindow *keyWin = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWin = w; break; }
            }
            if (keyWin) break;
        }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = keyWin.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void KSAlertShow(NSString *title, NSString *msg) {
    UIViewController *top = KSTopViewController();
    if (!top) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}

// ============================== 裸 socket HTTP（绕 ATS） ==============================

static NSData *KSHttpGetSync(NSString *urlString, NSTimeInterval timeout) {
    if (![urlString hasPrefix:@"http://"]) return nil;

    NSString *rest = [urlString substringFromIndex:7];
    NSRange slash = [rest rangeOfString:@"/"];
    NSString *hostPort = (slash.location == NSNotFound) ? rest : [rest substringToIndex:slash.location];
    NSString *path = (slash.location == NSNotFound) ? @"/" : [rest substringFromIndex:slash.location];

    NSString *host = hostPort;
    int port = 80;
    NSRange colon = [hostPort rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [hostPort substringToIndex:colon.location];
        port = [[hostPort substringFromIndex:colon.location + 1] intValue];
    }

    struct hostent *he = gethostbyname([host UTF8String]);
    if (!he) return nil;
    struct in_addr addr;
    memcpy(&addr, he->h_addr_list[0], sizeof(addr));

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;

    struct timeval tv;
    tv.tv_sec = (int)timeout;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr = addr;

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) { close(fd); return nil; }

    NSString *req = [NSString stringWithFormat:
        @"GET %@ HTTP/1.0\r\nHost: %@\r\nUser-Agent: KillSwitch/2.0\r\n"
         "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
        path, host];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
    if (send(fd, reqData.bytes, reqData.length, 0) < 0) { close(fd); return nil; }

    NSMutableData *resp = [NSMutableData data];
    char buf[4096];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof(buf), 0)) > 0) {
        [resp appendBytes:buf length:(NSUInteger)n];
        if (resp.length > 512 * 1024) break;
    }
    close(fd);
    if (resp.length == 0) return nil;

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r = [resp rangeOfData:sep options:0 range:NSMakeRange(0, resp.length)];
    if (r.location == NSNotFound) return nil;
    return [resp subdataWithRange:NSMakeRange(r.location + r.length,
                                              resp.length - r.location - r.length)];
}

// ============================== 设备码 ==============================

static NSString *KSMachineId(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *m = [d stringForKey:KS_UD_MACHINE];
    if (m.length) return m;

    NSString *idfv = nil;
    @try {
        idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    } @catch (NSException *e) { idfv = nil; }
    if (idfv.length == 0) idfv = [[NSUUID UUID] UUIDString];

    m = [[idfv stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    [d setObject:m forKey:KS_UD_MACHINE];
    [d synchronize];
    return m;
}

// ============================== 卡密验证 ==============================

static void KSAuthApplyFailure(NSInteger code, NSString *msg, BOOL fatal) {
    gAuthOK = NO;
    gCardMsg = msg.length ? msg : @"验证失败";
    NSLog(@"[KillSwitch] 卡密失败 code=%ld msg=%@", (long)code, gCardMsg);
    if (!fatal) return;

    UIViewController *top = KSTopViewController();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"卡密验证"
                                                               message:gCardMsg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) { kill(getpid(), SIGKILL); }]];
    if (top) {
        [top presentViewController:a animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ kill(getpid(), SIGKILL); });
    } else {
        kill(getpid(), SIGKILL);
    }
}

static void KSAuthVerify(NSString *key, void (^done)(BOOL ok, NSDictionary *info)) {
    NSString *machine = KSMachineId();
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&+?=# "];
    NSString *ek = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: key;

    NSString *url = [NSString stringWithFormat:@"%@?act=verify&key=%@&machine=%@", KS_API_BASE, ek, machine];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *body = KSHttpGetSync(url, 8);
        NSDictionary *json = nil;
        if (body.length) json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![json isKindOfClass:[NSDictionary class]]) {
                NSLog(@"[KillSwitch] 接口无响应/解析失败");
                gAuthFail++;
                if (done) done(NO, nil);
                return;
            }
            NSInteger code = [[json objectForKey:@"code"] integerValue];
            NSString *msg = [json objectForKey:@"msg"];
            NSLog(@"[KillSwitch] 验证返回 code=%ld msg=%@", (long)code, msg);
            if (code == 0) {
                gAuthFail = 0;
                gAuthOK = YES;
                gCardKey = key;
                gCardExpire = [json objectForKey:@"expire"] ?: @"";
                gCardDays = [[json objectForKey:@"days"] integerValue];
                gCardOnline = [[json objectForKey:@"online"] integerValue];
                gCardNote = [json objectForKey:@"note"] ?: @"";
                gCardMsg = msg ?: @"验证成功";
                [[NSUserDefaults standardUserDefaults] setObject:key forKey:KS_UD_KEY];
                [[NSUserDefaults standardUserDefaults] synchronize];
                if (done) done(YES, json);
            } else {
                if (done) { done(NO, json); return; }
                KSAuthApplyFailure(code, msg, NO);
            }
        });
    });
}

static void KSAuthPrompt(NSString *tip) {
    if (gPrompting) return;
    UIViewController *top = KSTopViewController();
    if (!top) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSAuthPrompt(tip); });
        return;
    }
    gPrompting = YES;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"卡密验证"
                                                              message:(tip.length ? tip : @"请输入卡密")
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"XXXX-XXXX-XXXX-XXXX";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (gCardKey.length) tf.text = gCardKey;
    }];

    __weak UIAlertController *weakA = a;
    [a addAction:[UIAlertAction actionWithTitle:@"验证" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        gPrompting = NO;
        NSString *k = [[(weakA.textFields.firstObject.text ?: @"")
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
        if (k.length == 0) { KSAuthPrompt(@"卡密不能为空"); return; }
        KSAuthVerify(k, ^(BOOL ok, NSDictionary *info) {
            if (ok) {
                KSAlertShow(@"验证成功",
                            [NSString stringWithFormat:@"到期：%@\n剩余 %ld 天 · 当前在线 %ld",
                             gCardExpire, (long)gCardDays, (long)gCardOnline]);
                KSInstallOnce();
            } else {
                NSInteger code = [[info objectForKey:@"code"] integerValue];
                NSString *msg = [info objectForKey:@"msg"] ?: @"验证失败";
                if (code == -2 || code == -3 || code == -4 || code == -5) KSAuthApplyFailure(code, msg, YES);
                else KSAuthPrompt(msg);
            }
        });
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        gPrompting = NO;
#if KS_KILL_WHEN_UNAUTH
        kill(getpid(), SIGKILL);
#endif
    }]];

    [top presentViewController:a animated:YES completion:nil];
}

void KSAuthKickOff(void) {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:KS_UD_KEY];
    if (saved.length) {
        gCardKey = saved;
        KSAuthVerify(saved, ^(BOOL ok, NSDictionary *info) {
            if (ok) {
                NSLog(@"[KillSwitch] 缓存卡密有效，剩余 %ld 天", (long)gCardDays);
                KSInstallOnce();
            } else {
                KSAuthPrompt([info objectForKey:@"msg"] ?: @"卡密校验失败");
            }
        });
    } else {
        KSAuthPrompt(@"首次使用请输入卡密");
    }
}

static void KSAuthHeartbeat(void) {
    if (gCardKey.length == 0) return;
    KSAuthVerify(gCardKey, ^(BOOL ok, NSDictionary *info) {
        if (!ok) {
            NSInteger code = [[info objectForKey:@"code"] integerValue];
            if (code == -3 || code == -4 || code == -5) {
                KSAuthApplyFailure(code, [info objectForKey:@"msg"], YES);
            }
        }
    });
}

// ============================== 远程开关 ==============================

static void KSLoadCache(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"ks_state"]) gKSOn = [d boolForKey:@"ks_state"];
}

static void KSSaveState(BOOL on, NSString *msg) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:@"ks_state"];
    [d setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"ks_state_time"];
    if (msg) [d setObject:msg forKey:@"ks_state_msg"];
    [d synchronize];
}

static void KSKillProcessNow(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_KILL_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ kill(getpid(), SIGKILL); });
}

static void KSEnforceOff(NSString *reason) {
    if (gKSAlert) return;
#if KS_SHOW_ALERT
    NSString *msg = reason.length ? reason : @"插件已被远程停用";
    gKSAlert = [UIAlertController alertControllerWithTitle:KS_TEXT_OFF message:msg
                                            preferredStyle:UIAlertControllerStyleAlert];
    [gKSAlert addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) { kill(getpid(), SIGKILL); }]];
    UIViewController *top = KSTopViewController();
    if (top) {
        [top presentViewController:gKSAlert animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ kill(getpid(), SIGKILL); });
    } else {
        kill(getpid(), SIGKILL);
        return;
    }
#else
    kill(getpid(), SIGKILL);
#endif
    KSKillProcessNow();
}

static void KSApplyState(BOOL on, NSString *message) {
    gKSOn = on;
    if (message) gKSMessage = message;
    KSSaveState(on, message);
    NSLog(@"[KillSwitch] 远程开关=%@ msg=%@", on ? @"开" : @"关", gKSMessage ?: @"");
    if (!on) { KSEnforceOff(gKSMessage); return; }
    if (gKSAlert) { [gKSAlert dismissViewControllerAnimated:NO completion:nil]; gKSAlert = nil; }
}

static BOOL KSParseBoolString(NSString *s, BOOL *out) {
    NSString *t = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([t isEqualToString:@"1"] || [t isEqualToString:@"on"] || [t isEqualToString:@"true"] ||
        [t isEqualToString:@"开"] || [t isEqualToString:@"开启"]) { *out = YES; return YES; }
    if ([t isEqualToString:@"0"] || [t isEqualToString:@"off"] || [t isEqualToString:@"false"] ||
        [t isEqualToString:@"关"] || [t isEqualToString:@"关闭"]) { *out = NO; return YES; }
    return NO;
}

static BOOL KSParseResponse(NSData *data, NSString *sign, BOOL *outOn, NSString **outMsg) {
    if (!data.length) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;

    if (KS_SECRET.length > 0 && sign.length > 0) {
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5(body.UTF8String, (CC_LONG)strlen(body.UTF8String), digest);
        NSMutableString *calc = [NSMutableString string];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [calc appendFormat:@"%02x", digest[i]];
        if (![calc.lowercaseString isEqualToString:sign.lowercaseString]) return NO;
    }

    NSString *trim = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL v = NO;
    if (KSParseBoolString(trim, &v)) {
        if (outOn) *outOn = v;
        if (outMsg) *outMsg = nil;
        return YES;
    }

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;

        id content = dict[@"content"];
        id encoding = dict[@"encoding"];
        if ([content isKindOfClass:[NSString class]] && [encoding isKindOfClass:[NSString class]] &&
            [(NSString *)encoding isEqualToString:@"base64"]) {
            NSString *b64 = [(NSString *)content stringByReplacingOccurrencesOfString:@"\n" withString:@""];
            b64 = [b64 stringByReplacingOccurrencesOfString:@"\r" withString:@""];
            NSData *inner = [[NSData alloc] initWithBase64EncodedString:b64
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (inner.length) return KSParseResponse(inner, nil, outOn, outMsg);
        }

        id val = dict[@"open"] ?: dict[@"status"] ?: dict[@"switch"] ?: dict[@"enable"] ?: dict[@"state"];
        NSString *msg = nil;
        id m = dict[@"msg"] ?: dict[@"message"] ?: dict[@"tip"];
        if ([m isKindOfClass:[NSString class]]) msg = m;
        if ([val isKindOfClass:[NSNumber class]]) {
            if (outOn) *outOn = [(NSNumber *)val boolValue];
            if (outMsg) *outMsg = msg;
            return YES;
        }
        if ([val isKindOfClass:[NSString class]] && KSParseBoolString((NSString *)val, &v)) {
            if (outOn) *outOn = v;
            if (outMsg) *outMsg = msg;
            return YES;
        }
    }
    return NO;
}

static NSURLSession *KSSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 8;
        cfg.timeoutIntervalForResource = 12;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

static void KSFetchFromIndex(NSUInteger idx, void (^done)(BOOL ok, BOOL on, NSString *msg)) {
    NSArray<NSString *> *urls = KSRemoteURLs();
    if (idx >= urls.count) { done(NO, NO, nil); return; }
    NSString *u = urls[idx];
    NSString *sep = [u containsString:@"?"] ? @"&" : @"?";
    NSString *urlStr = [NSString stringWithFormat:@"%@%@t=%ld", u, sep, (long)[[NSDate date] timeIntervalSince1970]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8;
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"KillSwitch/2.0" forHTTPHeaderField:@"User-Agent"];

    [[KSSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length) { KSFetchFromIndex(idx + 1, done); return; }
        NSString *sign = nil;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            sign = ((NSHTTPURLResponse *)resp).allHeaderFields[@"X-Sign"];
        }
        BOOL on = NO; NSString *msg = nil;
        if (KSParseResponse(data, sign, &on, &msg)) done(YES, on, msg);
        else KSFetchFromIndex(idx + 1, done);
    }] resume];
}

static void KSFetchOnce(void (^done)(BOOL ok, BOOL on, NSString *msg)) {
    NSDictionary *local = [NSDictionary dictionaryWithContentsOfFile:KS_LOCAL_FILE];
    if (local) {
        BOOL on = YES; NSString *msg = nil;
        id v = local[@"open"];
        if ([v isKindOfClass:[NSNumber class]]) on = [v boolValue];
        else if ([v isKindOfClass:[NSString class]]) KSParseBoolString(v, &on);
        id m = local[@"msg"];
        if ([m isKindOfClass:[NSString class]]) msg = m;
        done(YES, on, msg);
        return;
    }
    KSFetchFromIndex(0, done);
}

static void KSRefresh(BOOL force) {
    KSFetchOnce(^(BOOL ok, BOOL on, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) { gKSFailCount = 0; KSApplyState(on, msg); }
            else { gKSFailCount++; }
        });
    });
}

static void KSStartTimers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t checkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(checkTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                  (uint64_t)(KS_CHECK_INTERVAL * NSEC_PER_SEC), (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(checkTimer, ^{ KSRefresh(NO); });
        dispatch_resume(checkTimer);

        dispatch_source_t watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_WATCHDOG_INTERVAL * NSEC_PER_SEC)),
                                  (uint64_t)(KS_WATCHDOG_INTERVAL * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(watchdog, ^{ if (!gKSOn) KSEnforceOff(gKSMessage); });
        dispatch_resume(watchdog);

        dispatch_source_t beat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(beat, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_HEARTBEAT * NSEC_PER_SEC)),
                                  (uint64_t)(KS_HEARTBEAT * NSEC_PER_SEC), (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(beat, ^{ KSAuthHeartbeat(); });
        dispatch_resume(beat);
    });
}

static void KSStart(void) {
    if (gKSStarted) return;
    gKSStarted = YES;
    KSLoadCache();
    KSStartTimers();
    if (!gKSOn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSEnforceOff(gKSMessage); });
    }
    KSRefresh(YES);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { KSRefresh(YES); }];
}

BOOL KSIsEnabled(void) { return gKSOn; }
NSString *KSStatusText(void) { return gKSOn ? KS_TEXT_ON : KS_TEXT_OFF; }

// ============================================================================
//  设置页：卡密状态 + 远程开关
// ============================================================================

static const NSInteger KSSection  = 0;
static const NSInteger KSRowCard  = 0;
static const NSInteger KSRowSw    = 1;

static IMP gOrigRowCount   = NULL;
static IMP gOrigCellForRow = NULL;
static IMP gOrigDidSelect  = NULL;

static IMP gOrigViewDidLoad   = NULL;
static IMP gOrigDidUpdateLocs = NULL;
static IMP gOrigRouteTick     = NULL;
static IMP gOrigJumpToCoord   = NULL;
static IMP gOrigStartRoute    = NULL;
static IMP gOrigToggleIgnore  = NULL;

static BOOL KSHasOwnMethod(Class cls, SEL sel) {
    if (!cls) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) if (method_getName(list[i]) == sel) { found = YES; break; }
    if (list) free(list);
    return found;
}

static BOOL KSSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp) {
    if (!cls || !KSHasOwnMethod(cls, sel)) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *oldImp = method_setImplementation(m, newImp);
    return YES;
}

static NSInteger KS_rowCount(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger n = 0;
    if (gOrigRowCount) n = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))gOrigRowCount)(self, _cmd, tv, section);
    return (section == KSSection) ? (n + 2) : n;
}

static UITableViewCell *KS_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section == KSSection && ip.row == KSRowCard) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"KSCardCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"KSCardCell"];
        cell.detailTextLabel.numberOfLines = 2;
        cell.textLabel.text = @"卡密状态";
        if (gAuthOK) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 剩余 %ld 天 · 在线 %ld",
                                         gCardExpire.length ? gCardExpire : @"已授权", (long)gCardDays, (long)gCardOnline];
            cell.detailTextLabel.textColor = [UIColor systemGreenColor];
        } else {
            cell.detailTextLabel.text = gCardMsg.length ? gCardMsg : @"未验证（点此输入卡密）";
            cell.detailTextLabel.textColor = [UIColor systemRedColor];
        }
        cell.accessoryView = nil;
        return cell;
    }
    if (ip.section == KSSection && ip.row == KSRowSw) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"KSSwitchCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"KSSwitchCell"];
        cell.detailTextLabel.numberOfLines = 2;
        cell.textLabel.text = KSStatusText();
        cell.detailTextLabel.text = gKSMessage.length ? gKSMessage : @"远程开关（点此刷新）";
        cell.detailTextLabel.textColor = gKSOn ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = gKSOn;
        sw.enabled = NO;
        cell.accessoryView = sw;
        return cell;
    }

    if (!gOrigCellForRow) return nil;
    NSIndexPath *fixed = ip;
    if (ip.section == KSSection && ip.row >= 2) fixed = [NSIndexPath indexPathForRow:(ip.row - 2) inSection:ip.section];
    return ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))gOrigCellForRow)(self, _cmd, tv, fixed);
}

static void KS_didSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section == KSSection && ip.row == KSRowCard) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        if (gAuthOK) {
            KSAlertShow(@"卡密信息",
                        [NSString stringWithFormat:@"卡密：%@\n到期：%@\n剩余：%ld 天\n在线：%ld\n备注：%@",
                         gCardKey, gCardExpire, (long)gCardDays, (long)gCardOnline, gCardNote]);
        } else {
            KSAuthPrompt(@"请输入卡密");
        }
        return;
    }
    if (ip.section == KSSection && ip.row == KSRowSw) {
        KSRefresh(YES);
        [tv deselectRowAtIndexPath:ip animated:YES];
        return;
    }
    if (!gOrigDidSelect) return;
    NSIndexPath *fixed = ip;
    if (ip.section == KSSection && ip.row >= 2) fixed = [NSIndexPath indexPathForRow:(ip.row - 2) inSection:ip.section];
    ((void (*)(id, SEL, UITableView *, NSIndexPath *))gOrigDidSelect)(self, _cmd, tv, fixed);
}

// ---- A5 闸门 ----

static BOOL KSAllowFeature(void) { return gKSOn && gAuthOK; }

static void KS_viewDidLoad(id self, SEL _cmd) {
    if (!KSAllowFeature()) return;
    if (gOrigViewDidLoad) ((void (*)(id, SEL))gOrigViewDidLoad)(self, _cmd);
}
static void KS_didUpdateLocations(id self, SEL _cmd, id mgr, id locs) {
    if (!KSAllowFeature()) return;
    if (gOrigDidUpdateLocs) ((void (*)(id, SEL, id, id))gOrigDidUpdateLocs)(self, _cmd, mgr, locs);
}
static void KS_routeTimerTick(id self, SEL _cmd) {
    if (!KSAllowFeature()) return;
    if (gOrigRouteTick) ((void (*)(id, SEL))gOrigRouteTick)(self, _cmd);
}
static void KS_jumpToRealCoordinate(id self, SEL _cmd, id coord) {
    if (!KSAllowFeature()) return;
    if (gOrigJumpToCoord) ((void (*)(id, SEL, id))gOrigJumpToCoord)(self, _cmd, coord);
}
static void KS_startRouteSimulation(id self, SEL _cmd) {
    if (!KSAllowFeature()) return;
    if (gOrigStartRoute) ((void (*)(id, SEL))gOrigStartRoute)(self, _cmd);
}
static void KS_toggleIgnoreDistance(id self, SEL _cmd) {
    if (!KSAllowFeature()) return;
    if (gOrigToggleIgnore) ((void (*)(id, SEL))gOrigToggleIgnore)(self, _cmd);
}

void KSInstallOnce(void) {
    Class vc = objc_getClass("FNSettingsViewController");
    if (vc && !gOrigRowCount) {
        KSSwizzle(vc, @selector(tableView:numberOfRowsInSection:), (IMP)KS_rowCount, &gOrigRowCount);
        KSSwizzle(vc, @selector(tableView:cellForRowAtIndexPath:), (IMP)KS_cellForRow, &gOrigCellForRow);
        KSSwizzle(vc, @selector(tableView:didSelectRowAtIndexPath:), (IMP)KS_didSelect, &gOrigDidSelect);
        NSLog(@"[KillSwitch] 设置页挂载 rows=%@ cell=%@ sel=%@",
              gOrigRowCount ? @"ok" : @"miss", gOrigCellForRow ? @"ok" : @"miss", gOrigDidSelect ? @"ok" : @"miss");
    }

#if KS_GATE_FEATURES
    Class a5 = objc_getClass("A5");
    if (a5 && !gOrigViewDidLoad) {
        KSSwizzle(a5, @selector(viewDidLoad), (IMP)KS_viewDidLoad, &gOrigViewDidLoad);
        KSSwizzle(a5, @selector(locationManager:didUpdateLocations:), (IMP)KS_didUpdateLocations, &gOrigDidUpdateLocs);
        KSSwizzle(a5, @selector(routeTimerTick), (IMP)KS_routeTimerTick, &gOrigRouteTick);
        KSSwizzle(a5, @selector(jumpToRealCoordinate:), (IMP)KS_jumpToRealCoordinate, &gOrigJumpToCoord);
        KSSwizzle(a5, @selector(startRouteSimulation), (IMP)KS_startRouteSimulation, &gOrigStartRoute);
        KSSwizzle(a5, @selector(toggleIgnoreDistance), (IMP)KS_toggleIgnoreDistance, &gOrigToggleIgnore);
        NSLog(@"[KillSwitch] 功能闸门挂载 viewDidLoad=%@", gOrigViewDidLoad ? @"ok" : @"miss");
    }
#endif
}

static void KSInstallWithRetry(NSInteger left) {
    KSInstallOnce();
    BOOL page = (gOrigRowCount != NULL);
#if KS_GATE_FEATURES
    BOOL gate = (gOrigViewDidLoad != NULL);
#else
    BOOL gate = YES;
#endif
    if (page && gate) return;
    if (left <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ KSInstallWithRetry(left - 1); });
}

// ============================================================================
//  启动
// ============================================================================

__attribute__((constructor))
static void KillSwitchInit(void) {
    @autoreleasepool {
        NSLog(@"[KillSwitch] 加载 machine=%@", KSMachineId());
        KSStart();
        KSInstallWithRetry(120);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSAuthKickOff(); });
    }
}
