// ============================================================================
//  KillSwitch.xm  —  插件远程开关（开 / 关）
//
//  功能：
//    1. 从远程地址拉取开关状态（纯文本 1/0、on/off、开/关，或 JSON {"open":1}）
//    2. 在插件设置页顶部插入一行「远程开关」，中间文字随状态变化：
//         [开关]开[开关]   →   [开关]关[开关]
//    3. 远程下发「关」时：立即禁用插件逻辑，弹提示，然后强制结束 App 进程
//    4. 本地缓存 + 定时轮询 + 前后台切换复查 + 看门狗，杀掉进程后下次启动照样生效
//
//  编译：Theos（见 Makefile），产物 KillSwitch.dylib
//  注入：与插件一起注入宿主 App（全能签注入列表 / LC_LOAD_DYLIB / 越狱机放
//        /Library/MobileSubstrate/DynamicLibraries/ 并配同名 plist）
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <sys/sysctl.h>

// ============================== 用户配置区 ==============================

// 远程开关地址，按顺序尝试，任意一个返回有效值即采用
// 支持：纯文本 1/0、on/off、开/关、JSON {"open":1,"msg":"..."}
static NSArray<NSString *> *KSRemoteURLs(void) {
    return @[
        @"https://sharechain.qq.com/5de5cfd2d734c217472049e206d55e8c",   // 你给的分享链（见 README：需换成直链）
        @"https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/switch.json",
        @"https://your-domain.com/switch.txt"
    ];
}

// 请求签名密钥（服务端返回 sign=md5(body + 密钥)，留空则不校验）
#define KS_SECRET            @"CHANGE_ME_2024"

// 轮询间隔（秒）
#define KS_CHECK_INTERVAL    60.0
// 看门狗间隔（秒）：状态为「关」时确保进程必死
#define KS_WATCHDOG_INTERVAL 5.0
// 连续失败多少次后按「关」处理（0 = 永远按上次缓存处理，不因断网误杀）
#define KS_FAIL_LIMIT        0
// 缓存有效期（秒），超过这个时间没成功更新过，按「关」处理；0 = 不限制
#define KS_CACHE_TTL         0
// 「关」时是否弹窗提示（NO 则静默退出）
#define KS_SHOW_ALERT        1
// 弹窗后延迟多少秒杀进程
#define KS_KILL_DELAY        1.2

// 设置页里那一行显示的文字模板：%@ 会被替换成 开 / 关
#define KS_TEXT_ON           @"[开关]开[开关]"
#define KS_TEXT_OFF          @"[开关]关[开关]"

// 是否顺带把宿主插件的核心功能掐掉（0 = 只靠强杀，1 = 先掐功能再杀）
#define KS_GATE_FEATURES     1

// 本地调试开关文件（存在则优先生效，值为 1/0）
#define KS_LOCAL_FILE        @"/var/mobile/Library/Preferences/com.ks.remote.plist"

// ============================== 内部实现 ==============================

static NSString *const kKSKeyState   = @"ks_state";
static NSString *const kKSKeyTime    = @"ks_state_time";
static NSString *const kKSKeyMessage = @"ks_state_msg";

// 对外导出的两个小接口，前面先用声明，避免定义顺序问题
BOOL KSIsEnabled(void);
NSString *KSStatusText(void);

static BOOL        gKSOn        = YES;   // YES = 开，NO = 关
static BOOL        gKSStarted   = NO;
static NSInteger   gKSFailCount = 0;
static NSString   *gKSMessage   = @"";
static UIAlertController *gKSAlert = nil;

static NSString *KSNowString(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [f stringFromDate:[NSDate date]];
}

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

#pragma mark - 状态读写

static void KSLoadCache(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kKSKeyState]) {
        gKSOn = [d boolForKey:kKSKeyState];
    }
    gKSMessage = [d stringForKey:kKSKeyMessage] ?: @"";
}

static void KSSaveState(BOOL on, NSString *msg) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kKSKeyState];
    [d setObject:@([[NSDate date] timeIntervalSince1970]) forKey:kKSKeyTime];
    if (msg) [d setObject:msg forKey:kKSKeyMessage];
    [d synchronize];
}

#pragma mark - 强制退出

static void KSKillProcessNow(void) {
    // 先切断一切可能的后台保存，再 SIGKILL，避免用户数据被写脏
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_KILL_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        kill(getpid(), SIGKILL);
    });
}

static void KSEnforceOff(NSString *reason) {
    if (gKSAlert) return;   // 已经在弹了

#if KS_SHOW_ALERT
    NSString *msg = reason.length ? reason : @"插件已被远程停用";
    gKSAlert = [UIAlertController alertControllerWithTitle:KS_TEXT_OFF
                                                   message:msg
                                            preferredStyle:UIAlertControllerStyleAlert];
    [gKSAlert addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
        kill(getpid(), SIGKILL);
    }]];

    UIViewController *top = KSTopViewController();
    if (top) {
        [top presentViewController:gKSAlert animated:YES completion:nil];
    } else {
        // 界面还没起来就直接退出
        kill(getpid(), SIGKILL);
        return;
    }
    // 用户不点也拖不过 8 秒
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ kill(getpid(), SIGKILL); });
#else
    kill(getpid(), SIGKILL);
#endif
    KSKillProcessNow();
}

#pragma mark - 状态应用

static void KSApplyState(BOOL on, NSString *message) {
    BOOL changed = (on != gKSOn);
    gKSOn = on;
    if (message) gKSMessage = message;
    KSSaveState(on, message);

    NSLog(@"[KillSwitch] state=%@ msg=%@", on ? @"开" : @"关", gKSMessage ?: @"");

    if (!on) {
        KSEnforceOff(gKSMessage);
        return;
    }
    if (changed) {
        // 恢复时把可能存在的停用提示收掉
        if (gKSAlert) { [gKSAlert dismissViewControllerAnimated:NO completion:nil]; gKSAlert = nil; }
    }
}

#pragma mark - 响应解析

static BOOL KSParseBoolString(NSString *s, BOOL *out) {
    NSString *t = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                   lowercaseString];
    if ([t isEqualToString:@"1"] || [t isEqualToString:@"on"]  || [t isEqualToString:@"true"] ||
        [t isEqualToString:@"开"] || [t isEqualToString:@"开启"]) { *out = YES; return YES; }
    if ([t isEqualToString:@"0"] || [t isEqualToString:@"off"] || [t isEqualToString:@"false"] ||
        [t isEqualToString:@"关"] || [t isEqualToString:@"关闭"]) { *out = NO;  return YES; }
    return NO;
}

// 返回 YES 表示解析成功
static BOOL KSParseResponse(NSData *data, NSString *sign, BOOL *outOn, NSString **outMsg) {
    if (!data.length) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;

    // 1) 签名校验（可选）
    if (KS_SECRET.length > 0 && sign.length > 0) {
        // 服务端约定：sign = md5(body + KS_SECRET)
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5(body.UTF8String, (CC_LONG)strlen(body.UTF8String), digest);
        NSMutableString *calc = [NSMutableString string];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [calc appendFormat:@"%02x", digest[i]];
        if (![calc.lowercaseString isEqualToString:sign.lowercaseString]) {
            NSLog(@"[KillSwitch] sign 校验失败，丢弃本次响应");
            return NO;
        }
    }

    // 2) 纯文本
    NSString *trim = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL v = NO;
    if (KSParseBoolString(trim, &v)) {
        if (outOn) *outOn = v;
        if (outMsg) *outMsg = nil;
        return YES;
    }

    // 3) JSON
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        id val = dict[@"open"] ?: dict[@"status"] ?: dict[@"switch"] ?: dict[@"enable"] ?: dict[@"state"];
        NSString *msg = nil;
        id m = dict[@"msg"] ?: dict[@"message"] ?: dict[@"tip"];
        if ([m isKindOfClass:[NSString class]]) msg = m;

        if ([val isKindOfClass:[NSNumber class]]) {
            if (outOn) *outOn = [(NSNumber *)val boolValue];
            if (outMsg) *outMsg = msg;
            return YES;
        }
        if ([val isKindOfClass:[NSString class]]) {
            if (KSParseBoolString((NSString *)val, &v)) {
                if (outOn) *outOn = v;
                if (outMsg) *outMsg = msg;
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - 网络请求

static NSURLSession *KSSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest  = 8;
        cfg.timeoutIntervalForResource = 12;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

static void KSFetchOnce(void (^done)(BOOL ok, BOOL on, NSString *msg));

static void KSFetchFromIndex(NSUInteger idx, void (^done)(BOOL ok, BOOL on, NSString *msg)) {
    NSArray<NSString *> *urls = KSRemoteURLs();
    if (idx >= urls.count) { done(NO, NO, nil); return; }

    NSString *u = urls[idx];
    // 防缓存：拼时间戳
    NSString *sep = [u containsString:@"?"] ? @"&" : @"?";
    NSString *urlStr = [NSString stringWithFormat:@"%@%@t=%ld", u, sep, (long)[[NSDate date] timeIntervalSince1970]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8;
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"KillSwitch/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [KSSession() dataTaskWithRequest:req
                                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length) {
            NSLog(@"[KillSwitch] 拉取失败 %@ : %@", u, err.localizedDescription);
            KSFetchFromIndex(idx + 1, done);
            return;
        }
        NSString *sign = nil;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            sign = ((NSHTTPURLResponse *)resp).allHeaderFields[@"X-Sign"];
        }
        BOOL on = NO; NSString *msg = nil;
        if (KSParseResponse(data, sign, &on, &msg)) {
            done(YES, on, msg);
        } else {
            NSLog(@"[KillSwitch] 响应无法解析: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            KSFetchFromIndex(idx + 1, done);
        }
    }];
    [task resume];
}

static void KSFetchOnce(void (^done)(BOOL ok, BOOL on, NSString *msg)) {
    // 本地调试文件优先
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
            if (ok) {
                gKSFailCount = 0;
                KSApplyState(on, msg);
            } else {
                gKSFailCount++;
                NSLog(@"[KillSwitch] 本次更新失败（连续 %ld 次）", (long)gKSFailCount);
#if KS_FAIL_LIMIT > 0
                if (gKSFailCount >= KS_FAIL_LIMIT) KSApplyState(NO, @"远程开关校验失败");
#endif
#if KS_CACHE_TTL > 0
                NSTimeInterval t = [[NSUserDefaults standardUserDefaults] doubleForKey:kKSKeyTime];
                if (t > 0 && ([[NSDate date] timeIntervalSince1970] - t) > KS_CACHE_TTL) {
                    KSApplyState(NO, @"远程开关状态过期");
                }
#endif
            }
        });
    });
}

#pragma mark - 看门狗 / 定时器

static void KSStartTimers(void) {
    static dispatch_source_t checkTimer = nil;
    static dispatch_source_t watchdog    = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 轮询
        checkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(checkTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                  (uint64_t)(KS_CHECK_INTERVAL * NSEC_PER_SEC),
                                  (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(checkTimer, ^{ KSRefresh(NO); });
        dispatch_resume(checkTimer);

        // 看门狗：只要状态是关，任何时候都要死
        watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_main_queue());
        dispatch_source_set_timer(watchdog,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_WATCHDOG_INTERVAL * NSEC_PER_SEC)),
                                  (uint64_t)(KS_WATCHDOG_INTERVAL * NSEC_PER_SEC),
                                  (uint64_t)(1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(watchdog, ^{
            if (!gKSOn) KSEnforceOff(gKSMessage);
        });
        dispatch_resume(watchdog);
    });
}

static void KSStart(void) {
    if (gKSStarted) return;
    gKSStarted = YES;

    KSLoadCache();
    KSStartTimers();

    // 冷启动先同步查一次缓存状态：上次是「关」就立刻处理
    if (!gKSOn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSEnforceOff(gKSMessage); });
    }
    KSRefresh(YES);

    // 回前台立刻复查
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { KSRefresh(YES); }];
}

// 供插件其它代码调用：状态为关时直接拦死
BOOL KSIsEnabled(void) { return gKSOn; }
NSString *KSStatusText(void) { return gKSOn ? KS_TEXT_ON : KS_TEXT_OFF; }

// ============================================================================
//  设置页 UI：在插件设置页顶部插一行「远程开关」
//  宿主插件里的类名：FNSettingsViewController（蜂鸟众包插件 / 验证3.dylib）
//  若换别的插件，把下面三个 %hook 里的类名换掉即可
// ============================================================================

@interface FNSettingsViewController : UIViewController
@end

static const NSInteger KSSection = 0;   // 插在第 0 组
static const NSInteger KSRow     = 0;   // 第 0 行

%hook FNSettingsViewController

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
    if (section == KSSection) n += 1;
    return n;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == KSSection && ip.row == KSRow) {
        static NSString *cid = @"KSRemoteSwitchCell";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            // 左侧标题 + 右侧开关 + 中间状态文字 [开关]开[开关]
            UILabel *state = [[UILabel alloc] init];
            state.tag = 0x4B53;                     // 'KS'
            state.font = [UIFont boldSystemFontOfSize:16];
            state.textAlignment = NSTextAlignmentRight;
            state.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:state];

            UISwitch *sw = [[UISwitch alloc] init];
            sw.tag = 0x4B54;
            sw.translatesAutoresizingMaskIntoConstraints = NO;
            [sw addTarget:self action:@selector(ks_switchTapped:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:sw];

            [NSLayoutConstraint activateConstraints:@[
                [state.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-10],
                [state.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [sw.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [sw.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            ]];
        }
        cell.textLabel.text = @"远程开关";

        UILabel *state = [cell.contentView viewWithTag:0x4B53];
        UISwitch *sw    = [cell.contentView viewWithTag:0x4B54];
        state.text      = KSStatusText();
        state.textColor = gKSOn ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        sw.on           = gKSOn;
        sw.enabled      = NO;   // 状态由服务端决定，不让本地改
        return cell;
    }

    NSIndexPath *fixed = ip;
    if (ip.section == KSSection) fixed = [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
    return %orig(tv, fixed);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == KSSection && ip.row == KSRow) {
        KSRefresh(YES);
        [tv deselectRowAtIndexPath:ip animated:YES];
        return;
    }
    NSIndexPath *fixed = ip;
    if (ip.section == KSSection) fixed = [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
    %orig(tv, fixed);
}

// 点开关不做本地切换，只提示状态由远程控制
%new
- (void)ks_switchTapped:(UISwitch *)sw {
    sw.on = gKSOn;
    KSRefresh(YES);
}

%end

// ============================================================================
//  功能闸门：开关为「关」时，宿主插件主控制器 A5 的干活方法直接返回
//  （验证3.dylib 里 A5 是地图/定位主控制器，172 个方法都在这上面）
//  这只是「先掐功能」，真正的强制退出在 KSEnforceOff 里
// ============================================================================

#if KS_GATE_FEATURES

@interface A5 : UIViewController
@end

%hook A5

- (void)viewDidLoad {
    if (!gKSOn) return;
    %orig;
}

- (void)locationManager:(id)mgr didUpdateLocations:(id)locs {
    if (!gKSOn) return;
    %orig;
}

- (void)routeTimerTick {
    if (!gKSOn) return;
    %orig;
}

- (void)jumpToRealCoordinate:(id)coord {
    if (!gKSOn) return;
    %orig;
}

- (void)startRouteSimulation {
    if (!gKSOn) return;
    %orig;
}

- (void)toggleIgnoreDistance {
    if (!gKSOn) return;
    %orig;
}

%end

#endif

// ============================================================================
//  启动
// ============================================================================

%ctor {
    @autoreleasepool {
        KSStart();
        NSLog(@"[KillSwitch] 已加载，当前状态：%@", KSStatusText());
    }
}
