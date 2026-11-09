/*
 * KillSwitch.js —— 远程开关的 Frida 版（不用编译、不用重新打包）
 *
 * 用法：
 *   frida -U -f <宿主App bundleid> -l killswitch.js --no-pause
 *
 * 逻辑与 KillSwitch.xm 一致：
 *   - 每 60s 拉一次远程开关（多地址顺序重试）
 *   - 状态「开」→ 正常工作
 *   - 状态「关」→ 弹提示，1.2s 后 SIGKILL 掉 App；看门狗每 5s 复查
 *   - 本地调试文件优先：/var/mobile/Library/Preferences/com.ks.remote.plist
 */

const URLS = [
    "https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/switch.json",
    "https://your-domain.com/switch.txt"
];
const INTERVAL_MS = 60 * 1000;
const WATCHDOG_MS = 5 * 1000;
const LOCAL_FILE = "/var/mobile/Library/Preferences/com.ks.remote.plist";

let gOn = true;
let gBusy = false;
let gAlerted = false;

const log = (m) => console.log("[KS] " + m);

/* ---------- 本地调试文件 ---------- */
function readLocal() {
    try {
        const f = new File(LOCAL_FILE, "r");
        if (!f || !f.exists) return null;
        const txt = f.readAll().toString();
        f.close();
        const j = JSON.parse(txt);
        if (j && typeof j.open !== "undefined") return !!Number(j.open);
    } catch (e) { }
    return null;
}

/* ---------- 响应解析：1/0、on/off、开/关、JSON ---------- */
function parse(body) {
    if (body === null || body === undefined) return null;
    const t = String(body).trim().toLowerCase();
    if (["1", "on", "true", "开", "开启"].indexOf(t) >= 0) return true;
    if (["0", "off", "false", "关", "关闭"].indexOf(t) >= 0) return false;
    try {
        const j = JSON.parse(body);
        const v = (j.open !== undefined) ? j.open
            : (j.status !== undefined) ? j.status
            : (j.switch !== undefined) ? j.switch
            : (j.enable !== undefined) ? j.enable
            : j.state;
        if (v === 0 || v === 1 || typeof v === "boolean") return !!v;
        if (typeof v === "string") {
            const s = v.trim().toLowerCase();
            if (["1", "on", "true", "开", "开启"].indexOf(s) >= 0) return true;
            if (["0", "off", "false", "关", "关闭"].indexOf(s) >= 0) return false;
        }
    } catch (e) { }
    return null;
}

/* ---------- 单地址请求（借用宿主 App 的 NSURLSession） ---------- */
function fetchOne(url, cb) {
    let done = false;
    const finish = (v) => { if (!done) { done = true; cb(v); } };

    ObjC.schedule(ObjC.mainQueue, () => {
        try {
            const full = url + (url.indexOf("?") >= 0 ? "&" : "?") + "t=" + Date.now();
            const nsurl = ObjC.classes.NSURL.URLWithString_(full);
            const req = ObjC.classes.NSURLRequest.requestWithURL_cachePolicy_timeoutInterval_(nsurl, 1, 6.0);
            const conf = ObjC.classes.NSURLSessionConfiguration.ephemeralSessionConfiguration();
            const session = ObjC.classes.NSURLSession.sessionWithConfiguration_(conf);
            const task = session.dataTaskWithRequest_completionHandler_(req,
                new ObjC.Block({
                    retType: "void",
                    argTypes: ["object", "object", "object"],
                    implementation: function (data, resp, err) {
                        if (err !== null || data === null) { finish(null); return; }
                        const str = ObjC.classes.NSString.alloc()
                            .initWithData_encoding_(data, 4).toString();
                        finish(parse(str));
                    }
                }));
            task.resume();
        } catch (e) {
            log("请求异常: " + e);
            finish(null);
        }
    });

    setTimeout(() => finish(null), 8000);   // 兜底超时
}

function fetchState(cb) {
    const local = readLocal();
    if (local !== null) { cb(local); return; }
    const next = (i) => {
        if (i >= URLS.length) { cb(null); return; }
        fetchOne(URLS[i], (v) => (v === null ? next(i + 1) : cb(v)));
    };
    next(0);
}

/* ---------- 强杀 ---------- */
function killApp() {
    log("远程开关=关，1.2 秒后结束进程");
    setTimeout(() => {
        try {
            const kill = new NativeFunction(Module.getExportByName(null, "kill"), "int", ["int", "int"]);
            kill(Process.id, 9);   // SIGKILL
        } catch (e) {
            log("kill 失败: " + e);
        }
    }, 1200);
}

function enforce() {
    if (gAlerted) return;
    gAlerted = true;
    try {
        const alert = ObjC.classes.UIAlertController
            .alertControllerWithTitle_message_preferredStyle_("[开关]关[开关]", "插件已被远程停用", 1);
        const action = ObjC.classes.UIAlertAction.actionWithTitle_style_handler_("退出", 2,
            new ObjC.Block({
                retType: "void", argTypes: ["object"],
                implementation: function () { killApp(); }
            }));
        alert.addAction_(action);
        const app = ObjC.classes.UIApplication.sharedApplication();
        const keyWin = app.keyWindow();
        let vc = keyWin ? keyWin.rootViewController() : null;
        while (vc && vc.presentedViewController()) vc = vc.presentedViewController();
        if (vc) vc.presentViewController_animated_completion_(alert, true, null);
        else killApp();
    } catch (e) {
        log("弹窗失败，直接退出: " + e);
        killApp();
    }
    setTimeout(killApp, 8000);  // 用户不点也跑不掉
}

function apply(on) {
    if (on === null) return;
    if (on === gOn) return;
    gOn = on;
    log("状态切换 -> " + (on ? "[开关]开[开关]" : "[开关]关[开关]"));
    if (!on) enforce();
}

/* ---------- 主循环 ---------- */
function tick() {
    if (gBusy) return;
    gBusy = true;
    fetchState((v) => { gBusy = false; apply(v); });
}

setTimeout(() => {
    log("启动，开始轮询");
    tick();
    setInterval(tick, INTERVAL_MS);
    setInterval(() => { if (!gOn) enforce(); }, WATCHDOG_MS);
}, 1500);
