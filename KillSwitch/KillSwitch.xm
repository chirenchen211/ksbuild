// ============================================================================
//  KillSwitch.xm  -  ??????(? / ?)
//
//  ??:
//    1. ???????????(??? 1/0?on/off??/?,? JSON {"open":1})
//    2. ??????????????????,?????????:
//         [??]?[??]   ?   [??]?[??]
//    3. ????????:????????,???,?????? App ??
//    4. ???? + ???? + ??????? + ???,?????????????
//
//  ??:Theos(? Makefile),?? KillSwitch.dylib
//  ??:????????? App(??????? / LC_LOAD_DYLIB / ????
//        /Library/MobileSubstrate/DynamicLibraries/ ???? plist)
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

// ============================== ????? ==============================

// ??????,?????,????????????
// ??:??? 1/0?on/off??/??JSON {"open":1,"msg":"..."}
static NSArray<NSString *> *KSRemoteURLs(void) {
    return @[
        @"https://sharechain.qq.com/5de5cfd2d734c217472049e206d55e8c",   // ??????(? README:?????)
        @"https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/switch.json",
        @"https://your-domain.com/switch.txt"
    ];
}

// ??????(????? sign=md5(body + ??),??????)
#define KS_SECRET            @"CHANGE_ME_2024"

// ????(?)
#define KS_CHECK_INTERVAL    60.0
// ?????(?):?????????????
#define KS_WATCHDOG_INTERVAL 5.0
// ??????????????(0 = ?????????,??????)
#define KS_FAIL_LIMIT        0
// ?????(?),????????????,??????;0 = ???
#define KS_CACHE_TTL         0
// ??????????(NO ?????)
#define KS_SHOW_ALERT        1
// ???????????
#define KS_KILL_DELAY        1.2

// ??????????????:%@ ????? ? / ?
#define KS_TEXT_ON           @"[??]?[??]"
#define KS_TEXT_OFF          @"[??]?[??]"

// ????????????????(0 = ????,1 = ??????)
#define KS_GATE_FEATURES     1

// ????????(???????,?? 1/0)
#define KS_LOCAL_FILE        @"/var/mobile/Library/Preferences/com.ks.remote.plist"

// ============================== ???? ==============================

static NSString *const kKSKeyState   = @"ks_state";
static NSString *const kKSKeyTime    = @"ks_state_time";
static NSString *const kKSKeyMessage = @"ks_state_msg";

// ??????????,??????,????????
BOOL KSIsEnabled(void);
NSString *KSStatusText(void);

static BOOL        gKSOn        = YES;   // YES = ?,NO = ?
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

#pragma mark - ????

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

#pragma mark - ????

static void KSKillProcessNow(void) {
    // ????????????,? SIGKILL,?????????
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KS_KILL_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        kill(getpid(), SIGKILL);
    });
}

static void KSEnforceOff(NSString *reason) {
    if (gKSAlert) return;   // ?????

#if KS_SHOW_ALERT
    NSString *msg = reason.length ? reason : @"????????";
    gKSAlert = [UIAlertController alertControllerWithTitle:KS_TEXT_OFF
                                                   message:msg
                                            preferredStyle:UIAlertControllerStyleAlert];
    [gKSAlert addAction:[UIAlertAction actionWithTitle:@"??" style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *a) {
        kill(getpid(), SIGKILL);
    }]];

    UIViewController *top = KSTopViewController();
    if (top) {
        [top presentViewController:gKSAlert animated:YES completion:nil];
    } else {
        // ???????????
        kill(getpid(), SIGKILL);
        return;
    }
    // ???????? 8 ?
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ kill(getpid(), SIGKILL); });
#else
    kill(getpid(), SIGKILL);
#endif
    KSKillProcessNow();
}

#pragma mark - ????

static void KSApplyState(BOOL on, NSString *message) {
    BOOL changed = (on != gKSOn);
    gKSOn = on;
    if (message) gKSMessage = message;
    KSSaveState(on, message);

    NSLog(@"[KillSwitch] state=%@ msg=%@", on ? @"?" : @"?", gKSMessage ?: @"");

    if (!on) {
        KSEnforceOff(gKSMessage);
        return;
    }
    if (changed) {
        // ???????????????
        if (gKSAlert) { [gKSAlert dismissViewControllerAnimated:NO completion:nil]; gKSAlert = nil; }
    }
}

#pragma mark - ????

static BOOL KSParseBoolString(NSString *s, BOOL *out) {
    NSString *t = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                   lowercaseString];
    if ([t isEqualToString:@"1"] || [t isEqualToString:@"on"]  || [t isEqualToString:@"true"] ||
        [t isEqualToString:@"?"] || [t isEqualToString:@"??"]) { *out = YES; return YES; }
    if ([t isEqualToString:@"0"] || [t isEqualToString:@"off"] || [t isEqualToString:@"false"] ||
        [t isEqualToString:@"?"] || [t isEqualToString:@"??"]) { *out = NO;  return YES; }
    return NO;
}

// ?? YES ??????
static BOOL KSParseResponse(NSData *data, NSString *sign, BOOL *outOn, NSString **outMsg) {
    if (!data.length) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;

    // 1) ????(??)
    if (KS_SECRET.length > 0 && sign.length > 0) {
        // ?????:sign = md5(body + KS_SECRET)
        unsigned char digest[CC_MD5_DIGEST_LENGTH];
        CC_MD5(body.UTF8String, (CC_LONG)strlen(body.UTF8String), digest);
        NSMutableString *calc = [NSMutableString string];
        for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [calc appendFormat:@"%02x", digest[i]];
        if (![calc.lowercaseString isEqualToString:sign.lowercaseString]) {
            NSLog(@"[KillSwitch] sign ????,??????");
            return NO;
        }
    }

    // 2) ???
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

#pragma mark - ????

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
    // ???:????
    NSString *sep = [u containsString:@"?"] ? @"&" : @"?";
    NSString *urlStr = [NSString stringWithFormat:@"%@%st=%ld", u, sep, (long)[[NSDate date] timeIntervalSince1970]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 8;
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"KillSwitch/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [KSSession() dataTaskWithRequest:req
                                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data.length) {
            NSLog(@"[KillSwitch] ???? %@ : %@", u, err.localizedDescription);
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
            NSLog(@"[KillSwitch] ??????: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            KSFetchFromIndex(idx + 1, done);
        }
    }];
    [task resume];
}

static void KSFetchOnce(void (^done)(BOOL ok, BOOL on, NSString *msg)) {
    // ????????
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
                NSLog(@"[KillSwitch] ??????(?? %ld ?)", (long)gKSFailCount);
#if KS_FAIL_LIMIT > 0
                if (gKSFailCount >= KS_FAIL_LIMIT) KSApplyState(NO, @"????????");
#endif
#if KS_CACHE_TTL > 0
                NSTimeInterval t = [[NSUserDefaults standardUserDefaults] doubleForKey:kKSKeyTime];
                if (t > 0 && ([[NSDate date] timeIntervalSince1970] - t) > KS_CACHE_TTL) {
                    KSApplyState(NO, @"????????");
                }
#endif
            }
        });
    });
}

#pragma mark - ??? / ???

static void KSStartTimers(void) {
    static dispatch_source_t checkTimer = nil;
    static dispatch_source_t watchdog    = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ??
        checkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(checkTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                                  (uint64_t)(KS_CHECK_INTERVAL * NSEC_PER_SEC),
                                  (uint64_t)(5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(checkTimer, ^{ KSRefresh(NO); });
        dispatch_resume(checkTimer);

        // ???:??????,???????
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

    // ?????????????:???????????
    if (!gKSOn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ KSEnforceOff(gKSMessage); });
    }
    KSRefresh(YES);

    // ???????
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { KSRefresh(YES); }];
}

// ?????????:?????????
BOOL KSIsEnabled(void) { return gKSOn; }
NSString *KSStatusText(void) { return gKSOn ? KS_TEXT_ON : KS_TEXT_OFF; }

// ============================================================================
//  ??? UI:?????????????????
//  ????????:FNSettingsViewController(?????? / ??3.dylib)
//  ??????,????? %hook ????????
// ============================================================================

@interface FNSettingsViewController : UIViewController
@end

static const NSInteger KSSection = 0;   // ??? 0 ?
static const NSInteger KSRow     = 0;   // ? 0 ?

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

            // ???? + ???? + ?????? [??]?[??]
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
        cell.textLabel.text = @"????";

        UILabel *state = [cell.contentView viewWithTag:0x4B53];
        UISwitch *sw    = [cell.contentView viewWithTag:0x4B54];
        state.text      = KSStatusText();
        state.textColor = gKSOn ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        sw.on           = gKSOn;
        sw.enabled      = NO;   // ????????,?????
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

// ?????????,??????????
%new
- (void)ks_switchTapped:(UISwitch *)sw {
    sw.on = gKSOn;
    KSRefresh(YES);
}

%end

// ============================================================================
//  ????:???????,???????? A5 ?????????
//  (??3.dylib ? A5 ???/??????,172 ????????)
//  ?????????,???????? KSEnforceOff ?
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
//  ??
// ============================================================================

%ctor {
    @autoreleasepool {
        KSStart();
        NSLog(@"[KillSwitch] ???,????:%@", KSStatusText());
    }
}
