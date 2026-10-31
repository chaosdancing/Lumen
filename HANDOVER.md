# Lumen 交接文档

> 更新时间：2026-10-31  
> 分支：`main`（已推送，工作区干净）  
> 最近提交：`eb4ddf6 macOS 去筛选箭头；iPad 顶栏去框、搜索收进更多、首页上移`  
> 版本：0.1.5 (Build 13)

---

## 1. 项目概况

Lumen 是本地 / NAS 影视库播放器：

- SwiftUI，iOS 17+ / macOS 14+；
- 视频内核：MPVKit（libmpv），部分场景 AVFoundation；
- 工程由 XcodeGen 管理：改 `project.yml` 后执行 `xcodegen generate`；
- 包名 / Bundle ID：
  - macOS：`com.example.lumen.mac`
  - iOS：`com.consynia.lumen`
- Development Team：`WZ6AS9TRW2`（macOS 请用签名构建，见第 5 节）。

主要目录：

```
Sources/App/          App 入口、macOS/iPad 根视图、侧边栏、顶栏
Sources/Core/         Store、MediaSource、Metadata/TMDB、Keychain、字幕解析
Sources/UI/           Home、Detail、Player、Settings、Components
Tests/iOS/            iPad UI 测试
Tools/                install-ipad.sh 等
project.yml           XcodeGen 工程定义
```

---

## 2. 当前产品形态

### macOS

- 分栏侧边栏（`NavigationSplitView`），不是悬浮面板；
- 主窗口透明标题栏 + 全尺寸内容，头图顶到窗口最上沿；
- 首页头图约 0.88 屏高，影片区压在磨砂层上，只露约一多半卡片；
- 电影 / 电视剧列表页启用首条内容的虚化背景，整页跟随背景色调；
- 排序 / 筛选菜单已隐藏系统下拉箭头；
- 右侧、详情页、侧边栏滚动条为自绘细胶囊，滚动时浮现、停止约 0.9 秒后淡出；
- 详情页选集区不再有灰色卡片底，直接浮在模糊背景上；
- 右上角“更多”菜单只显示三个点（无下拉箭头）。

### iPad

- 顶栏：
  - 左侧一级栏目下拉（媒体库 / 偏好 / 文件源 / 服务器 / 设置），无外框；
  - 中间「继续观看 / 电影 / 电视剧」或偏好分类胶囊；
  - 右上角搜索 / 三个点均无外框（iOS 26 的工具栏玻璃底也已隐藏）；
  - 继续观看 / 电影 / 电视剧的搜索已收进「…」菜单；
  - 偏好下所有页面不提供搜索入口。
- 首页头图约 0.62 屏高，继续观看上移，底部约露一排半卡片；
- 电视剧详情头图 0.76 比例，选集模块使用轻磨砂；
- iPhone 仍是 4 个 Tab，页面内搜索与分类入口保留，不受 iPad 顶栏改动影响。

### 设置

已按 `Lumen设置-现代.html` 重做：

- 搜索、深浅色切换；
- 三张概览卡：媒体库 / 已刮削 / iCloud 同步；
- 七张偏好卡片：通用、资源、同步、播放、播放器界面、字幕和音轨、隐私与安全；
- 每张卡片进入独立详情页，卡片式行布局、新版开关；
- 原有设置项全部保留；
- 底部显示真实版本与「无遥测 · 无上报」。

注意：设计稿里的「存储占用」暂时用「已刮削」替代，因为目前没有做库体积 / 缓存体积统计。

### 字幕 / 播放

- 外挂字幕支持语言后缀：`影片.chs.srt`、`影片.zh-CN.ass`、`影片.eng.forced.srt` 等；
- 多字幕优先级：简中 > 繁中 > 英文；
- 字幕背景默认**透明**，设置 → 字幕和音轨 → 「字幕背景」可切「透明 / 半透明」；
- 字幕文件编码支持 UTF-8 / UTF-16 / GB18030，CRLF 已处理。

### 演员 / 元数据

- 演员作品当前使用 **TMDB `combined_credits`**（本地优先方案已回滚）；
- 本地优先 / 本地 + TMDB 降级 + 缓存的方案在历史提交中，可按需取回，但要注意本地扫描会读 NAS，性能敏感。

---

## 3. 最近提交（从新到旧）

```
eb4ddf6 macOS 去筛选箭头；iPad 顶栏去框、搜索收进更多、首页上移
15283e5 字幕背景默认透明，可在字幕设置里切换半透明
d03ce9b 字幕：支持带语言后缀的外挂字幕（.chs.srt 等）
33af6d5 设置页重做：卡片概览 + 分组详情；演员页回滚 TMDB 方案
cf895f9 macOS：演员作品降级聚合缓存、悬浮滚动条、详情页过渡带
cf11442 macOS：侧边栏恢复分栏、选集区融入背景、演员本地计算、自绘滚动条
25060a2 macOS 浮动侧边栏 + 电影/电视剧背景联动 + 启动工具栏位置
8eded73 macOS 首页只露半排卡片 + 背景色调联动 + 侧边栏滚动条
```

---

## 4. 关键文件

| 文件 | 作用 |
|---|---|
| `Sources/App/LumenApp.swift` | 入口、macOS 侧边栏/窗口、iPad 一级栏目与顶栏、SectionMenu |
| `Sources/UI/HomeView.swift` | 首页 / 电影 / 电视剧 / 偏好列表、Hero、iPad 顶栏按钮、自绘主滚动条 |
| `Sources/UI/DetailView.swift` | 详情页、头图、选集、演职人员、详情滚动条 |
| `Sources/UI/SettingsView.swift` | 新设置页概览 + 详情 + 各 Pane |
| `Sources/UI/PlayerView.swift` | 播放器、外挂字幕渲染、字幕背景 |
| `Sources/UI/Components.swift` | HeroCarousel、BlurredBackdrop、自绘滚动条、公共控件 |
| `Sources/Core/Store.swift` | 媒体库、扫源、字幕候选匹配、Keychain/Credentials |
| `Sources/Core/Metadata.swift` | TMDB、元数据缓存、TMDB Key |
| `Sources/Core/Subtitles.swift` | SRT / ASS / VTT 解析与编码探测 |
| `Sources/Core/Preferences.swift` | 所有偏好项（外观、播放、字幕、外观等） |
| `Tests/iOS/LibraryNavigationTests.swift` | iPad 顶栏、搜索、设置、详情 UI 测试 |

---

## 5. 构建与验证

### 生成工程

```bash
cd /Users/consynia/AI_Project/Lumen
xcodegen generate
```

### macOS（要验钥匙串时务必签名构建）

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/dd-mac build
```

不要加 `CODE_SIGNING_ALLOWED=NO`。ad-hoc 签名会让 macOS 认为每次构建都是不同应用，钥匙串会反复弹授权。签名版第一次访问点 **“始终允许”**，之后同 Team/证书的构建不再重复弹。

### iOS 构建 / 测试

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-ios build

xcodebuild test -project Lumen.xcodeproj -scheme Lumen-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/dd-tests \
  -only-testing:Lumen-UnitTests \
  -only-testing:Lumen-iOS-UITests/LibraryNavigationTests \
  CODE_SIGNING_ALLOWED=NO
```

已知：`testCarouselSwipeAndRotation` 在模拟器上是历史遗留失败，不是新回归。

### 真机 iPad

```bash
./Tools/install-ipad.sh EB06D667-D31C-581C-8061-4C77CC47B395
```

设备锁屏或 Developer Disk Image 未挂载时会安装失败；解锁、亮屏、联网后重试。

---

## 6. 待办 / 已知问题

1. **电视剧详情“紫色高度一半”未精确落位**
   - 目前只做了：头图加高到 0.76、选集模块轻磨砂；
   - 用户所说“每季的卡片下移紫色高度一半”还需要一张电视剧页截图并圈出“紫色高度”指哪块，才能精确调整。
2. **设置概览的存储占用**
   - 现在是「已刮削」代替设计稿的「存储占用」；如需严格还原，需要补索引 / 缓存体积统计。
3. **演员作品方案**
   - 当前纯 TMDB；本地优先与本地 + 降级 + 缓存方案在历史提交里，重新启用前要先解决 NAS 频繁读取的性能问题。
4. **macOS 窗口截图**
   - 当前终端没有屏幕录制权限，无法自动截 macOS 窗口；iPad 模拟器截图可正常生成。
5. **钥匙串**
   - 只解决了“每次构建都弹”的签名问题；首次授权仍需点一次“始终允许”。
   - 若后续要完全无弹窗，可评估 Data Protection Keychain，但需要 entitlements / 迁移。
6. **iPad 顶栏**
   - 已移除栏目选择、搜索、三个点的外框；中间分类胶囊仍保留自己的材质底，这是刻意保留的。
7. **macOS / iPad 差异**
   - 所有“只针对 macOS”的改动都用 `#if os(macOS)` 隔离；改 Home / Detail / Settings 时注意不要重新把 macOS 的入口带到 iPad。

---

## 7. 交接检查清单

- [ ] 改动 `project.yml` 后执行 `xcodegen generate`
- [ ] macOS 用签名构建，不要 `CODE_SIGNING_ALLOWED=NO`
- [ ] 同时跑 macOS + iOS Simulator 构建
- [ ] iPad UI 测试至少跑 `LibraryNavigationTests`
- [ ] 改 iPad 顶栏时确认 iPhone 仍保留页面内搜索
- [ ] 字幕改动注意语言后缀与编码
- [ ] 演员页改动注意不要引入全库扫描，避免 NAS 性能问题
- [ ] 提交前确认工作区干净、已推送 `origin/main`

---

## 8. 仓库

```
git@github.com:chaosdancing/Lumen.git
```
