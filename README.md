# Lumen

一个**独立实现**的 macOS / iPadOS 媒体库播放器。功能与交互逻辑对齐 VidHub 那套设计，但代码、UI、图标、文案全部原创 —— 不包含任何第三方应用的资源。

> 构建状态：macOS ✅ `BUILD SUCCEEDED` ｜ iOS Simulator ✅ `BUILD SUCCEEDED`
> 当前版本：0.1.0（里程碑 1）

---

## 1. 它做了什么

| 能力 | 状态 |
|---|---|
| 本地文件夹作为媒体源（安全作用域书签） | ✅ |
| WebDAV 作为媒体源（PROPFIND + Basic Auth） | ✅ |
| 在线直链（HTTP/HTTPS） | ✅ |
| 递归扫描 + 文件名解析（S01E02 / 1x02 / 第01集 / 年份） | ✅ |
| **剧集聚合**：同一部剧的多集合并成一张卡片，点进去按季/集展开 | ✅ |
| **详情页**：大封面 + 季选择 + 集列表（集号/文件大小/观看进度） | ✅ |
| **封面三级回退**：媒体服务器官方海报 → 同目录 poster/folder/cover.jpg → 本地视频抽帧 → 渐变占位 | ✅ |
| **首页**：大图轮播（整幅剧照，往下淡出成整页虚化背景，跟详情页同一套）+ 继续观看 / 剧集 / 电影 三行，每行右侧「全部 ›」跳到对应模块 | ✅ |
| **侧边栏两级分组**：媒体库（继续观看/最近添加/电影/电视剧/未观看/已观看/收藏夹）+ 文件源（每个源一行 + 条目数）+ 底部状态区 | ✅ |
| **无边框海报网格**：2:3 图 + 集数角标 + 进度条 + 标题/年份在图下方，悬停浮播放键 | ✅ |
| **详情页 hero 版式**：整屏大图（约 0.75 窗口高，跟窗口自适应）+ smoothstep 遮罩把剧照"化"进页面底色（无接缝）+ 38pt 大标题 + 元信息行 + 白色胶囊播放键 + 圆形次级按钮 + 右侧简介 + 规格胶囊 | ✅ |
| 列表页顶部：排序菜单 / 未观看筛选 / 网格-列表切换 | ✅ |
| 收藏夹（右键收藏，落盘 favorites.json） | ✅ |
| **播放器**：顶部标题栏 + 中央播放/±10s + 底部进度/字幕/倍速，单击隐藏、双击暂停、空格/←/→/Esc 快捷键 | ✅ |
| **列表筛选**：全部 / 未观看 / 最近添加 | ✅ |
| 剧集详情：海报模糊背景 + 选集网格（集号/进度/已看完角标） | ✅ |
| 播放（AVPlayer）+ 进度记忆 + 倍速 | ✅ |
| 同目录字幕自动加载（SRT / ASS / SSA / VTT）+ 手动切换 + 字号 | ✅ |
| **内嵌多音轨 / 多字幕选择**：MKV 里自带的音轨、字幕轨在播放页下拉可选（语言代码翻成中文），外挂字幕与内嵌字幕互斥 | ✅ |
| Emby / Jellyfin 媒体服务器（API Key 鉴权、海报、直连播放） | ✅ |
| 海报：媒体服务器取官方封面；本地/WebDAV 用渐变占位 | ✅ |
| 密码 / API Key 存钥匙串，不落 JSON | ✅ |
| SMB 源 | ⛔️ 待 AMSMB2（代码位置已留好） |
| **MKV / AVI / RMVB / ISO / 杜比视界（libmpv 内核）** | ✅ 已接入 MPVKit 1.1.0-n9.0.2（macOS） |
| 在线字幕搜索（OpenSubtitles / SubHD 之类） | ⛔️ 里程碑 3 |
| Plex | ⛔️ 里程碑 3（API 与 Emby 类似，加个 token 头即可） |
| 投屏（DLNA / Chromecast） | ⛔️ 里程碑 4 |

---

## 2. 架构对照

这是把前面逆向出来的机制，用干净的方式重写了一遍：

| VidHub 的做法（逆向结论） | Lumen 的对应实现 |
|---|---|
| `OmiFileProvider` 把 14 种后端收敛成统一 `FileObject` 树 | `MediaSource` 协议 + `MediaSourceFactory`，每种源一个实现 |
| `FileSourceProviderEntity → FileSourceEntity → MediaItemEntity` 三层 | `MediaSourceConfig → MediaItem`，JSON 持久化 |
| `launchWith2_0(...)` 统一播放入口 | `PlayerView.load()` → `AppStore.playURL(for:)` |
| `MVPlayerCore.MediaPlayerProtocol` + `OmiMPV.MPVManager` 分层 | `PlayerEngine` 协议 + `AVPlayerEngine`（M2 换成 `MPVEngine`） |
| 密码/授权走 Keychain | `Keychain`（`kSecClassGenericPassword`） |
| 播放进度本地记录 | `PlaybackRecord` + `AppStore.record(...)` |

关键设计点：**播放内核是可替换的**。`PlayerEngine` 只有 7 个方法（load/play/pause/seek/setRate/isPlaying/时长），换内核不用动 UI 和进度逻辑。

---

## 3. 目录

```
Lumen/
├── project.yml                 # XcodeGen 工程定义（改这个，别手改 .xcodeproj）
├── Lumen.entitlements          # 沙盒 + 网络客户端 + 用户选择文件
├── Lumen.xcodeproj             # 由 xcodegen generate 生成
└── Sources/
    ├── App/LumenApp.swift      # @main、侧边栏/标签栏导航
    ├── Core/
    │   ├── Models.swift        # SourceKind / MediaSourceConfig / MediaItem / PlaybackRecord
    │   ├── Sources.swift       # MediaSource 协议 + Local / WebDAV / SMB(占位)
    │   ├── MediaServerSource.swift  # CatalogSource 协议 + Emby/Jellyfin 客户端
    │   ├── Subtitles.swift     # SRT/ASS/VTT 解析 + 当前 cue 二分查找
    │   ├── Scanner.swift       # 文件名 → 结构化条目
    │   └── Store.swift         # Keychain + 持久化 + 扫描 + 进度 + 海报/字幕入口（AppStore）
    └── UI/
        ├── HomeView.swift      # 首页 + 媒体库 + 海报卡片
        ├── SourcesView.swift   # 源列表 + 添加源
        ├── PlayerView.swift    # PlayerEngine 协议 + AVPlayer 实现 + 播放页
        └── SettingsView.swift  # 设置/关于
```

---

## 3.5 本地验证记录（macOS 26.6 / Xcode 26.6 / Swift 6.3）

| 项 | 结果 |
|---|---|
| 干净编译（ad-hoc 签名 `Sign to Run Locally`） | `BUILD SUCCEEDED` |
| iOS Simulator 编译 | `BUILD SUCCEEDED` |
| 启动 | 进程常驻、前台、`sandboxed`，无崩溃报告 |
| 沙盒容器 | `~/Library/Containers/com.example.lumen.mac/Data/Library/Application Support/Lumen/` 正常创建 |
| 端到端扫描 | 塞入 2 个真实 `.mov` + 2 个 `.srt` → 自动扫描落盘 `library.json`，2 条：`S02E05 / The Mandalorian / S2E5` 与 `Inception / 2010`，size 正确 |
| 播放源可读 | `AVURLAsset` 读到 16.01s / 1 条视频轨 / 400×258 |
| 字幕匹配 | 同目录 `.srt` 解析 2 条，`t=1.0` → `This is the way.`，`t=4.0` → 中文行 |
| 文件名解析回归 | 7 个真实命名 + 6 个嵌套/中文目录用例全部正确 |

### 修复记录（用户实测反馈）

| 现象 | 根因 | 修法 |
|---|---|---|
| 侧边栏点了没反应（第一次修） | `List(_:selection:)` 的行上又叠了 `.tag(item as SidebarSection?)`，覆盖了集合初始化的自动 id 标签 | 去掉 `.tag`，保留 `Binding<SelectionValue?>` 重载 |
| 侧边栏点了没反应（第二次修） | 仍依赖 `List` 的选择语义（集合初始化器的 selection 类型是元素 `ID`，不是元素本身） | **改成每行一个 `Button` + 自己维护选中态与高亮**，彻底不依赖 List selection；加 ⌘1–⌘4 快捷键兜底 |
| 播放黑屏 / 画面不对 | `PlayerEngine.makeSurface()` 返回 `AnyView`，视图身份被擦除；进度每 0.5s 刷新一次 body，`AVPlayerLayer` 就被重建一次 | 删掉 `makeSurface()`，直接挂 `MacPlayerLayerView`/`IOSPlayerLayerView`；`NSView` 只建一次，不再替换 `view.layer` |
| 连局域网 NAS 失败 | ATS 默认拦明文 `http://`；macOS 15+ 还需要本地网络权限说明 | `Info.plist` 加 `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription` + `NSBonjourServices` |
| WebDAV 播放 401 | AVPlayer 不带 Basic 认证头 | 新增 `PlaybackTarget(url:headers:)`，用 `AVURLAssetHTTPHeaderFieldsKey` 注入 `Authorization`；`URLSession` 侧同样带 |

### 诊断工具（无 UI 自动化权限时的替代手段）

macOS 的 Accessibility 权限拿不到，`osascript`/`CGEvent` 都点不动 UI，所以内置了两个探针：

| 探针 | 触发方式 | 作用 |
|---|---|---|
| 自检 | 在容器 `…/Application Support/Lumen/` 放一个 `selftest.flag`，再启动应用 | 程序化把 4 个 section 切一遍，把结果写进 `selftest.txt`，验证状态机 |
| 点击日志 | 正常点侧边栏 | 每次点击往 `click.log` 追加一行，用来判断「事件有没有到达 Button」 |
| 运行日志 | 自动 | `lumen.log`：记录连接测试的完整参数与 `NSError` 细节（domain#code + underlying） |

`log show` 在沙盒里跑不了（`log: Cannot run while sandboxed`），所以网络问题一律看 `lumen.log`。

主机字段做了容错，下面四种输入等价：

```
http://192.168.3.29:5005/video   ← 整条 URL 粘进来
192.168.3.29:5005                ← 带端口
192.168.3.29 + 端口 5005 + 路径 /video
192.168.3.29（端口留空 → http 走 80 / https 走 443）
```

实测自检输出：

```
SELFTEST v0.1.1 (1)
set section=home -> current=home
set section=library -> current=library
set section=sources -> current=sources
set section=settings -> current=settings
reset -> home
```

> 复现方式：把视频放进容器内的 `Sample/` 目录，再写一份 `sources.json`（`kind=local`、`basePath` 指向该目录、无 `bookmark`）。应用首次启动会自动扫描。

---

## 4. 构建

```bash
cd Lumen
xcodegen generate            # 已装：brew install xcodegen
open Lumen.xcodeproj         # 选 Lumen-macOS 或 Lumen-iOS 直接 Run
```

命令行验证：

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen-macOS -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Lumen.xcodeproj -scheme Lumen-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

真机跑 iPad 需要在 Xcode 里选自己的 Team（`project.yml` 的 `DEVELOPMENT_TEAM` 留空是故意的）。

---

## 5. libmpv 已接入（MKV/AVI/RMVB/ISO 可播）

`project.yml` 里声明了 SPM 依赖：

```yaml
packages:
  MPVKit:
    url: https://github.com/mpvkit/MPVKit
    exactVersion: 1.1.0-n9.0.2
```

三个关键点（都踩过）：

1. **`import Libmpv` 不可用** —— MPVKit 的产品只暴露一个空的 `_MPVKit` C target，C 头文件没模块化。改用 `@_silgen_name` 直接声明 `mpv_create` / `mpv_initialize` 等符号（`Sources/UI/MPVAPI.swift`），链接期由 MPVKit 带进来的静态符号解析。
2. **`@_silgen_name` 不会自动把 Swift String 转成 C 字符串** —— 必须 `withCString`，否则传野指针，`mpv_initialize` 直接让进程退出。
3. **hardened runtime 会杀掉 mpv 初始化** —— 需要 `com.apple.security.cs.disable-library-validation` + `allow-jit` + `allow-unsigned-executable-memory`（已在 `Lumen.entitlements`）。

Xcode 命令行解析依赖还需要：

```bash
defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
```

否则 SwiftPM 编译 Package.swift 时 `sandbox-exec` 嵌套失败。

验证（无界面探针，真实 NAS 上的 MKV）：

```
MPV PROBE init rc=0
MPV PROBE 成功 duration=5185.2s 1920x1040 耗时500ms
```

播放内核按扩展名分流：mp4/mov/m4v → AVPlayer；其余 → libmpv。

**画面走 render API，不是 `wid`**（关键）：

```
NSOpenGLView (3.2 Core, 双缓冲)
  → mpv_render_context_create(api="opengl", get_proc_address=dlsym)
  → mpv 的 update 回调 → needsDisplay
  → draw() 里 mpv_render_context_render(fbo=0, flipY=1) → flushBuffer()
```

`--wid` + `vo=gpu` 在沙盒 + Metal 下会让进程直接退出（无 crash report）；换成 render API 后
`vo=libmpv` 一切正常。MediaCenter（VidHub）也是同一套架构：沙盒 + 进程内 libmpv + render API。

实测（真实 NAS 上的 MKV）：

```
GL 上下文就绪，准备创建 mpv render context
mpv 初始化 rc=0（render API 模式）
mpv render context 创建成功（opengl）
mpv 已渲染 1 帧（1280x720）
GL PROBE 成功 duration=3129.3s 播放中=true 耗时500ms
```

## 5.1 旧计划（保留作参考）：接 libmpv

AVPlayer 只吃 MP4/MOV 与 HLS，这是当前最大的短板。接 MPVKit 后一步到位：

1. Xcode → File → Add Package Dependencies：
   `https://github.com/mpvkit/MPVKit`
2. 在 `project.yml` 里加（这样 xcodegen 重生成也不会丢）：

   ```yaml
   packages:
     MPVKit:
       url: https://github.com/mpvkit/MPVKit
       from: "0.39.0"
   targets:
     Lumen-macOS:
       dependencies: [{ package: MPVKit, product: MPVKit }]
     Lumen-iOS:
       dependencies: [{ package: MPVKit, product: MPVKit }]
   ```
3. 新增 `Sources/Core/MPVEngine.swift`，实现 `PlayerEngine`：

   ```swift
   import Libmpv

   final class MPVEngine: PlayerEngine {
       private let mpv = mpv_create()
       // 初始化参数（照抄 VidHub 的取舍）
       //   input-media-keys=no, keep-open=no, audio-display=no
       //   hwdec=auto（VideoToolbox）, audio-device=auto
       //   sub-auto=fuzzy, sub-codepage=auto, sub-ass-override=force
       //   vo=gpu-next（嵌入式渲染）
       // macOS 上最简单：mpv_set_option_string(mpv, "wid", "\(nsViewPointer)")
       // iOS 上必须走 render API：mpv_render_context_create + OpenGL ES/Metal
   }
   ```
4. 在 `PlayerView` 里把 `@StateObject private var engine = AVPlayerEngine()` 换成 `MPVEngine()`，其余不动。

> macOS 上用 `wid` 把 mpv 塞进 `NSView`，这条路最省事，也正是 VidHub 的做法（`gpu-next` + `wid` 嵌入）。iOS 没有 `wid`，必须用 `mpv_render_context_*`。

## 6. 里程碑 2 附带：SMB

1. SPM 添加 `https://github.com/amosavian/AMSMB2`
2. 实现 `SMBMediaSource.list`：`SMB2Manager.connectShare` + `contentsOfDirectory`
3. 实现 `SMBMediaSource.playURL`：mpv 读不了 `smb://`，需要**本地 HTTP 中转** ——
   起一个最小 HTTP 服务（支持 `Range`），把 AMSMB2 的字节流出去，再把 `http://127.0.0.1:port/...` 交给播放器。

## 6.5 局域网源（NAS）注意事项

实测一台群晖（`192.168.3.29`）：

| 探测 | 结果 |
|---|---|
| `192.168.3.29:5006` | **Connection refused**（WebDAV HTTPS 没开） |
| `http://192.168.3.29:5005/video/` | `401`，`WWW-Authenticate: Basic realm="SYNO_WebDAV Storage"` |
| `5001 / 80 / 443` | 开（DSM 管理界面） |

所以群晖的 WebDAV 实际地址是 **`http://<IP>:5005/<共享名>`**，填源时：
- 类型选 WebDAV
- 主机 `192.168.3.29`、端口 `5005`、根路径 `/video`
- **关掉**「使用 HTTPS」（5006 没开）
- 用户名/密码填 DSM 的账号密码

第一次连局域网时系统会弹「Lumen 想访问本地网络」，必须点允许，否则请求会被静默拒绝。

## 7. 字幕实现（已验证）

`Sources/Core/Subtitles.swift` 纯 Foundation，无依赖：

- **SRT / VTT**：按空行切块，找 `-->` 行，时间戳支持 `,` 与 `.` 两种小数分隔
- **ASS / SSA**：进 `[Events]` 段，按 `Format:` 行动态定位 `Text` 字段（因为 Text 里可能带逗号），去掉 `{\an8}` 之类内联标签，`\N` 转真换行
- **编码嗅探**：UTF-8 → UTF-16 → GB18030 → Latin1（老字幕常见 GBK）
- **取当前字幕**：按 start 二分，再回退处理长台词重叠

用真实样例跑过（`swiftc` 独立编译验证，未进 App）：

```
SRT cues: 2
  1.00-3.50  第一行字幕
  4.00-6.00  第二行⏎跨行文本
ASS cues: 2
  1.00-3.50  第一条 ASS
  4.00-6.00  第二条⏎换行
active@2.0 -> 第一行字幕   active@5.0 -> 第二条换行   active@3.8 -> nil（间隙）
```

播放页的行为：进入即扫同目录同主文件名的字幕 → 自动选第一个 → 右下角字幕按钮可切换/关闭/调字号。

### 界面截图自检（没有录屏权限也能截图）

在 `~/Library/Application Support/Lumen/` 下放两个 flag，启动即自动跑：

- `detail-test.flag`：内容为片名或库内相对路径 → 启动后直接跳进该条目的详情页
- `shot.flag`：内容为 `1440x900`（可追加 `dark` 强制深色外观）→ 把主窗口抓成 `shot.png`

抓图走 `CGWindowListCreateImage(.optionIncludingWindow)`：抓自己的窗口不需要屏幕录制权限。
`NSView.cacheDisplay` / `CALayer.render(in:)` 对 SwiftUI 的 hosting view 只会得到一张白图，不要用。

## 8. 里程碑 3/4

- 字幕：扫描同目录 `.srt/.ass`，`PlayerView` 里挂 `AVPlayerItemLegibleOutput`（AVPlayer）或 `sub-add`（mpv）
- 媒体服务器：Plex/Emby/Jellyfin 各自实现 `MediaSource`，把 `/library/sections` 之类的返回映射成 `MediaItem`
- 投屏：DLNA 用 SSDP 发现 + SOAP AVTransport；Chromecast 用 Cast SDK

---

## 9. 已知限制

- 本地/WebDAV 没有海报刮削（不联网），海报位是渐变色占位；媒体服务器有官方封面。要刮削接 TMDB，或读同目录 `poster.jpg`
- 没有剧集聚合（同一部剧的多个 episode 目前平铺显示）
- WebDAV 解析只取 `href / resourcetype / getcontentlength`，够用但不完整
- 文件名解析是启发式，复杂的命名（多版本、合集）会误判

---

## 10. 与 VidHub 的关系

本项目是**功能对齐的独立实现**，用于学习媒体播放器的工程结构。没有使用 VidHub 的二进制、代码、图标、nib、文案或本地化表；也不包含任何绕过其授权校验的逻辑。
