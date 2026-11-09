# KillSwitch 远程开关（Windows 用户版）

这个仓库只干一件事：**让 GitHub 的免费云电脑帮你把 `KillSwitch.dylib` 编译出来**。
你这边是 Windows 也没关系，全程只用浏览器，不用装 Xcode、不用装 Linux、不用装 Theos。

---

## 先说清楚 GitHub Actions 是什么

> GitHub 是存代码的网站，它附带一个免费的"云电脑"服务叫 **Actions**。
> 你把代码传上去，点一下按钮，它就在一台 **Mac** 上跑编译命令（`make`），
> 编完把 `KillSwitch.dylib` 打包成一个 zip 让你下载。
> 免费额度：公开仓库完全免费、不限时长（私有仓库每月 2000 分钟，也够用几百次）。

所以我们做的事情就是：**把代码传上去 → 点一下 → 下载编译好的 dylib**。

---

## 一、准备（2 分钟）

1. 打开 https://github.com 注册账号（邮箱 + 密码，验证一下邮箱）。
2. 把本文件夹解压到桌面，比如 `C:\Users\你\Desktop\ks`。
   解压后应该看到：
   ```
   ks\
   ├─ .github\workflows\build.yml     ← 云编译脚本（别改名、别丢）
   └─ KillSwitch\
      ├─ KillSwitch.xm                ← 源码
      ├─ Makefile
      ├─ control
      ├─ KillSwitch.plist
      └─ killswitch.js
   ```
   > `.github` 是隐藏文件夹（名字以点开头），Windows 资源管理器里可能看不见。
   > 文件 → 查看 → 勾选「隐藏的项目」就能看到。**它必须一起上传**，否则 Actions 不会出现。

---

## 二、上传（3 分钟）

1. 登录 GitHub，右上角 `+` → **New repository**。
2. Repository name 填 `ks`，选 **Public**，其它不勾，点 **Create repository**。
3. 新页面中间有 "…or upload an existing file"，点 **uploading an existing file**。
4. 把 `ks` 文件夹里的 **所有内容**（`.github` 和 `KillSwitch` 两个文件夹）一起拖进网页。
   - 拖文件夹进去会自动保留目录结构。
   - 如果拖不进去，就用 **Add file → Upload files** 再选一次文件夹。
5. 下面 Commit changes 随便写一句，点 **Commit changes**。

---

## 三、编译（点两下）

1. 仓库顶部点 **Actions** 标签。
2. 如果提示 "Workflows aren't being run on this repository"，
   点绿色按钮 **I understand my workflows, go ahead and enable them**。
3. 左边列表点 **build** → 右边点 **Run workflow** → 绿色 **Run workflow**。
4. 等 2～4 分钟，页面出现一个带绿勾的运行记录，点进去。
5. 滚到最下面 **Artifacts** → 点 **KillSwitch-dylib** 下载。
6. 解压得到 `KillSwitch.dylib`（几百 KB），**这就是成品**。

> 编译失败（红叉）？点进去看日志，最常见是 SDK 下载超时，重新 Run 一次就好。

---

## 四、装到手机上

1. 把 `KillSwitch.dylib` 和 `验证3.dylib`（已经打过补丁、内嵌了 `@loader_path/KillSwitch.dylib` 的那个）
   放在**同一个目录**。
2. 全能签里把这两个一起注入、签名、安装。
3. 打开 App → 插件设置页顶部会多一行：

   ```
   远程开关              [开关]开[开关]   ●──
   ```

服务端把状态改成 `0` 后，最多 60 秒内会变成 `[开关]关[开关]`，弹提示并**强制退出 App**。

---

## 五、服务端开关放哪

`KillSwitch.xm` 顶部 `KSRemoteURLs()` 里填你的地址，改完提交，Actions 会自动重编一次。

推荐（免费、稳定、手机就能改）：

1. 在同一个 GitHub 仓库里放一个 `switch.json`：
   ```json
   { "open": 1, "msg": "正常" }
   ```
   然后在 `KSRemoteURLs()` 里填：
   ```
   https://raw.githubusercontent.com/你的用户名/ks/main/switch.json
   ```
2. 要停用所有人：把 `1` 改成 `0` 提交，等一个轮询周期（≤60 秒）全部生效。

> 你原来给的 `sharechain.qq.com/...` 是微云分享页，返回的是网页不是数据，
> 拿来做开关源会一直解析失败（客户端会保持上次状态，不会误杀）。
> 想用微云也行，得先解析出直链，麻烦且会 403，不建议。

---

## 六、不想用 GitHub 的三个备选

| 方案 | 难度 | 说明 |
|---|---|---|
| **Frida 版**（`killswitch.js`） | ★ | 越狱机可跑：`frida -U -f <bundleid> -l killswitch.js`，逻辑完全一样，不用编译 |
| **WSL2 + Theos** | ★★★★ | 装 WSL2 Ubuntu，再按 theos 官方 Linux 教程装工具链 + iOS SDK，几个 GB、坑不少，不推荐新手 |
| **找台 Mac / 借用** | ★★ | 装 Theos 后 `cd KillSwitch && make`，产物在 `.theos/obj/arm64/KillSwitch.dylib` |

改完 `KillSwitch.xm` 想重新编译：仓库里 Commit 一下 → Actions 自动跑 → 重新下载，不用重复上面的注册步骤。
