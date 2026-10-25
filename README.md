# Lumen

独立实现的 macOS / iPadOS 媒体库播放器，使用 SwiftUI、AVFoundation 和 MPVKit。最低支持 macOS 14、iOS 17，工程版本为 0.1.1。

## 功能

- 媒体源：本地文件夹（安全作用域书签）、WebDAV（Basic Auth）、HTTP/HTTPS 视频直链、Emby / Jellyfin（API Key）。
- 媒体库：递归扫描、按剧名聚合与季/集选择、收藏和观看进度；支持电影年代、类型、floor 评分和分级分类，以及独立搜索与推荐观看。
- 元数据和封面：本地 NFO 优先，TMDB 补充缺失字段；元数据、海报、背景和演员头像缓存至本机及可写媒体源的 `.lumen-cache`。
- 详情页可手动更新元数据或重新扫描当前文件／剧集；元数据补齐后同步刷新分类。顶部标题栏提供排序与观看状态筛选。
- 播放：AVPlayer 与 libmpv 双后端，续播、倍速、内嵌音轨/字幕切换、外挂 SRT / ASS / SSA / VTT。
- 字幕编码：UTF-8、带 BOM 或可靠字节特征的 UTF-16、GB18030、Latin1；支持重叠字幕查询。
- 密码和 API Key 由 `Credentials` 管理；正式构建使用钥匙串，Debug 构建有本地开发凭据回退。

## 架构

| 模块 | 实现 |
|---|---|
| 媒体源 | `MediaSource`、`CatalogSource`、`MediaSourceFactory` |
| 扫描与持久化 | `AppStore`、`MediaItemParser`、`SeriesGroup`；JSON 保存媒体库、进度和收藏 |
| 元数据 | `MetadataStore`、`TMDBClient`、`NFOParser` |
| 封面 | `ArtworkStore`、`LocalArtworkResolver`，按源、变体、偏好和修订隔离缓存 |
| 播放 | `PlayerPresenter` → `AppStore.playbackTarget(for:)` → `PlayerCore` |
| 渲染 | AVPlayerLayer；macOS NSOpenGLView / iOS GLKView 的 mpv render API |

`PlaybackTarget` 携带 URL、认证头和媒体源租约，播放器卸载媒体后释放租约。扫描、元数据和播放加载使用请求代次或会话校验，避免取消或切换后旧任务回写。

## 目录

```text
project.yml                  XcodeGen 工程定义
Lumen.xcodeproj              生成的工程
Lumen.entitlements           macOS 沙盒及 mpv 运行权限
Sources/App/                 应用入口与导航
Sources/Core/                源、扫描、存储、元数据、封面、字幕、诊断
Sources/UI/                  媒体库、详情、文件浏览、播放器、设置
Tools/install-ipad.sh        编译并安装到连接的 iOS 设备
```

工程配置优先修改 `project.yml`，再用 XcodeGen 生成工程。

## 构建

需要 Xcode 和 XcodeGen。MPVKit 依赖固定为 `1.1.0-n9.0.2`。

```bash
xcodegen generate
open Lumen.xcodeproj
```

选择 `Lumen-macOS` 或 `Lumen-iOS`。真机签名需将开发团队改为自己的 Team；当前工程和安装脚本包含本项目的团队配置。

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen-macOS -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Lumen.xcodeproj -scheme Lumen-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

./Tools/install-ipad.sh [设备ID]
```

安装脚本要求本次构建成功，只安装该次独立 DerivedData 中的产物；启动失败会返回非零状态。

可独立检查全部 Swift 源码的类型（不验证 MPVKit 链接、资源打包或签名）：

```bash
xcrun swiftc -typecheck -swift-version 5 -enable-bare-slash-regex \
  -target arm64-apple-macosx14.0 $(rg --files Sources -g '*.swift')

LUMEN_IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc -typecheck -swift-version 5 -enable-bare-slash-regex \
  -sdk "$LUMEN_IOS_SDK" -target arm64-apple-ios17.0 \
  $(rg --files Sources -g '*.swift')
```

2026-10-25 修复验证：macOS 未签名完整构建成功，两平台全源码类型检查通过；已验证真实 NAS 的 HEV1 MP4 回退播放和剧集局部扫描。元数据、WebDAV 缓存、分类及观看进度刷新使用隔离数据回归。iOS 真机安装和播放尚未验证；本机完整 iOS 构建仍受缺失平台组件限制。

## 播放内核

MP4 / MOV / M4V / HLS 优先 AVPlayer，其他支持的视频扩展名使用 libmpv；AV 视频轨不兼容或读取失败时回落 mpv，解决部分 HEV1 MP4 有声音但黑屏的问题。iOS 对文件名中识别出的 4K / HDR / Dolby Vision 内容优先 AVPlayer，该判断属于启发式。

MPVKit 的 libmpv 符号通过 `Sources/UI/MPVAPI.swift` 的 C ABI 声明访问，字符串参数必须通过 `withCString`。画面使用 `vo=libmpv` 和 `mpv_render_context_*`，由宿主 GL 上下文绘制。macOS 与 iOS 均使用 render API。

## 诊断

flag 文件位于应用的 `Application Support/Lumen/`，macOS 沙盒构建位于应用容器内。仅在 flag 存在时执行相应探针。

| 文件 | 内容及作用 |
|---|---|
| `mpv-test.flag` | 库内相对路径；无窗口检查 mpv 时长和视频尺寸 |
| `mpv-wid-test.flag` | 库内相对路径；以真实窗口检查当前 GL render API |
| `meta-test.flag` | 库内相对路径；检查 NFO / TMDB 调用 |
| `thumb-test.flag` | 每行一个库内相对路径；检查封面和字幕链路，最多四条 |
| `shot.flag` | 如 `1440x900 dark`；窗口截图写入 `shot.png`，可附 `quick` 或 `player` |

窗口截图使用 macOS 14+ ScreenCaptureKit，需要系统屏幕录制权限。未授权或截取失败会记录错误；不以空白图片报告成功。连接与探针细节可查看 `lumen.log`。

局域网源需允许系统的本地网络访问。WebDAV 的协议、端口和根路径应以服务端实际配置为准；HTTPS 默认端口为 443，HTTP 为 80。

## 已知限制

- SMB 为占位实现；Plex、在线字幕搜索及 DLNA / Chromecast 投屏尚未实现。
- 文件名与 iOS HDR 判断为启发式，多版本、合集或非标准命名可能误判。
- mpv 播放中的截图暂不支持，界面会明确提示；AV 截图携带播放认证头。
- macOS OpenGL 与 iOS OpenGLES 已废弃，当前仍依赖它们进行 mpv 渲染。
- 回归使用临时隔离探针，当前没有正式 Xcode 测试 target。
- 媒体源缓存使用独立、不可覆盖的版本文件；重复更新会增长存储，尚未提供自动清理策略。

## 与 VidHub 的关系

本项目用于学习媒体播放器的工程结构，功能与交互参考 VidHub；代码、UI、图标和文案独立实现，不包含第三方应用资源或授权绕过逻辑。
