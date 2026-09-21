# 灶记 ZAOJI

家庭菜谱手账：**Android 用 App、iPhone 用 Web（免装 App）、数据与同步服务跑在自家电脑上**。
没有云账号——服务器就在家里局域网里，全设备增量同步（HLC + 变更日志 + 冲突箱）。

预发布的安装包（Android APK + 服务端 exe + Web 产物，含图文部署步骤）见
[Releases](../../releases)；本文件面向**部署者与开发者**。

```
babyco/
├─ app/      Flutter 客户端（Android + Web 同一套代码）
├─ server/   Dart shelf 服务端（同步 / 媒体 / 状态页 / HTTPS）
└─ shared/   纯 Dart 库（HLC、合并算法、同步协议模型）
```

---

## 一、只部署，不开发（拿到 Release 四件套）

在**家里常开的那台 Windows 电脑**上：

1. 建一个固定目录（数据、证书、日志都在 exe 旁边生成），如 `D:\zaoji\`。
2. `zaoji_server.exe` 放 `D:\zaoji\`；`zaoji_web_*.zip` 解压到 `D:\zaoji\web\`（保证 `web\index.html` 存在）。
3. 生成局域网证书（iPhone 走 HTTPS 必需）：把仓库里的 `server/tool/make-cert.ps1`
   放到 `D:\zaoji\tool\`，运行
   `powershell -ExecutionPolicy Bypass -File tool\make-cert.ps1`
   （自动带上本机局域网 IP；IP 变了重跑即可，CA 复用、手机信任不用重装）。
4. 启动：`zaoji_server.exe -w web`（默认 `8666` HTTP / `8667` HTTPS）。
5. 本机浏览器打开 `http://127.0.0.1:8666/` → 状态页显示版本号、`webReady: true` 即成功。

**前端接入：**

- **Android**：装 `app-arm64-v8a-release.apk`（很老的入门机用 `armeabi-v7a`），允许未知来源；与服务器同一局域网即可用。
- **iPhone（网页版）**：先把服务端电脑 `certs\ca.crt` 传到手机安装描述文件，并在
  设置 → 通用 → 关于本机 → **证书信任设置**里打开「ZAOJI Local CA」的完全信任，
  再访问 `https://<家里IP>:8667/`。
- 接入方式由服务端「我的 → 同步」的准入模式决定：**open 免配对（默认）/ 固定口令 / 配对码**。

## 二、Web 前端到底怎么「启动」

没有独立的生产启动命令——Web 前端是**静态产物，由服务端托管**：

```powershell
# 构建唯一入口（app/tool/ 下）：内置离线自足校验，禁止直接 flutter build web
cd app; powershell -File tool\build_web.ps1
# 产物在 app\build\web，然后让服务端托管它：
zaoji_server.exe -w ..\app\build\web     # 浏览器访问 https://<IP>:8667/
```

开发态热重载：`cd app; flutter run -d chrome`，在 App 的「我的 → 同步」里手动填家里的
服务端地址（如 `http://192.168.31.x:8666`）——只有被服务端托管时才会自动预填当前 origin。

## 三、源码开发

环境：Flutter stable（3.x，Dart ≥3.10）、Dart SDK（服务端/shared 用）。
中国大陆网络构建 APK 时加 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`。

```powershell
# 服务端（仓库根起）：开发运行 / 编译 / 测试
cd server; dart pub get
dart run bin/zaoji_server.dart -w ..\app\build\web
dart compile exe bin/zaoji_server.dart -o zaoji_server.exe
dart test                      # 全量（当前 224 个）

# 客户端（Android 调试直跑；Web 见上文）
cd app; flutter pub get; flutter test    # 当前 144 个

# 共享库
cd shared; dart test           # 当前 126 个
```

服务端 `data/`、`certs/`、`logs/` 一律相对 **exe（或运行时入口）所在目录**解析——
把编译产物放哪，数据就跟到哪；换机器部署 = 整个目录拷走。

## 四、更多

- 每一轮的决策、踩坑与验收记录在项目内的交接文档（进度日志，不随仓库发布）。
- 已知边界：真机人工验收清单未完成（通知 / WakeLock / Web 后台节流等 M2 项）；
  App 底部「备菜」tab 为占位，备菜入口在菜单详情页。
- 服务端仅面向家庭局域网，请勿直接暴露公网。
