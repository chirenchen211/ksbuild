/*
 * KillSwitch.js -- ????? Frida ?(???????????)
 *
 * ??:
 *   frida -U -f <??App bundleid> -l killswitch.js --no-pause
 *
 * ??? KillSwitch.xm ??:
 *   - ? 60s ???????(???????)
 *   - ?????? ????
 *   - ?????? ???,1.2s ? SIGKILL ? App;???? 5s ??
 *   - ????????:/var/mobile/Library/Preferences/com.ks.remote.plist
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

/* ---------- ?????? ---------- */
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

/* ---------- ????:1/0?on/off??/??JSON ---------- */
function parse(body) {
    if (body === null || body === undefined) return null;
    const t = String(body).trim().toLowerCase();
    if (["1", "on", "true", "?", "??"].indexOf(t) >= 0) return true;
    if (["0", "off", "false", "?", "??"].indexOf(t) >= 0) return false;
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
            if (["1", "on", "true", "?", "??"].indexOf(s) >= 0) return true;
            if (["0", "off", "false", "?", "??"].indexOf(s) >= 0) return false;
        }
    } catch (e) { }
    return null;
}

/* ---------- ?????(???? App ? NSURLSession) ---------- */
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
            log("????: " + e);
            finish(null);
        }
    });

    setTimeout(() => finish(null), 8000);   // ????
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

/* ---------- ?? ---------- */
function killApp() {
    log("????=?,1.2 ??????");
    setTimeout(() => {
        try {
            const kill = new NativeFunction(Module.getExportByName(null, "kill"), "int", ["int", "int"]);
            kill(Process.id, 9);   // SIGKILL
        } catch (e) {
            log("kill ??: " + e);
        }
    }, 1200);
}

function enforce() {
    if (gAlerted) return;
    gAlerted = true;
    try {
        const alert = ObjC.classes.UIAlertController
            .alertControllerWithTitle_message_preferredStyle_("[??]?[??]", "????????", 1);
        const action = ObjC.classes.UIAlertAction.actionWithTitle_style_handler_("??", 2,
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
        log("????,????: " + e);
        killApp();
    }
    setTimeout(killApp, 8000);  // ????????
}

function apply(on) {
    if (on === null) return;
    if (on === gOn) return;
    gOn = on;
    log("???? -> " + (on ? "[??]?[??]" : "[??]?[??]"));
    if (!on) enforce();
}

/* ---------- ??? ---------- */
function tick() {
    if (gBusy) return;
    gBusy = true;
    fetchState((v) => { gBusy = false; apply(v); });
}

setTimeout(() => {
    log("??,????");
    tick();
    setInterval(tick, INTERVAL_MS);
    setInterval(() => { if (!gOn) enforce(); }, WATCHDOG_MS);
}, 1500);
