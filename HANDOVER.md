# Lumen 交接文档

> 更新时间：2026-11-01  
> 分支：`main`（已合并 `feature/nas-shared-library`）  
> 合并提交：`e9aacee`；feature 最后提交：`2a9dc78`  
> 版本：0.1.5 (Build 13)  
> 工作区：干净，`origin/main` 已推送

## 最近完成

- **NAS 共享库**：刮削元数据、观看进度、收藏写入媒体源 `.lumen-cache`；换机/重装扫描即可复用。
- **收藏取消跨设备删除**：`favorite:false + updatedAt` tombstone；另一台设备启动/扫描/回前台/立即同步时应用。
- **设置页**：现代卡片概览；三张统计卡等高；右侧改为 NAS 同步状态；同步页增加共享开关。
- **年代/类型/评分/分级**：不再进入页面就全库 `scrapeAll`，直接用共享元数据。
- **电视剧季度选择**：能全宽放下就展示全部；放不下才出箭头，箭头只滚动列表，不直接切季。
- **iPad 详情/轮播**：详情版式、横屏贴底、首页轮播推荐与页码、封面点击进详情已合入 main。
- **macOS 便携构建**：本机 `/Applications/Lumen.app` 使用开发签名；其他机器使用 `dist/0.1.5/Lumen-0.1.5-macOS-arm64-adhoc-2a9dc78.zip`（临时 ad-hoc，未公证）。

---

## 1. 项目概况

SwiftUI 本地 / NAS 影视库播放器：

- iOS 17+ / macOS 14+；
- MPVKit（libmpv）+ AVFoundation；
- XcodeGen：改 `project.yml` 后执行 `xcodegen generate`；
- Bundle ID：
  - macOS `com.example.lumen.mac`
  - iOS `com.consynia.lumen`
- Development Team：`WZ6AS9TRW2`。

主要目录：

```
Sources/App/          App 入口、macOS 侧边栏、iPad 顶栏
Sources/Core/         Store、媒体源、Metadata/TMDB、字幕、共享库同步
Sources/UI/           Home、Detail、Player、Settings、Components
Tests/Unit/           单元测试（含 SharedLibrarySyncTests）
Tests/iOS/            iPad UI 测试
Tools/install-ipad.sh 真机安装脚本
project.yml           XcodeGen 工程定义
Docs/                 设计/共享库说明
dist/                 便携版 zip（不跟 git 提交）
```

---

## 2. 当前产品形态

### macOS

- `NavigationSplitView` 侧边栏，不是悬浮面板；
- 透明标题栏 + 全尺寸内容，头图顶到窗口上沿；
- 首页头图约 0.88 屏高，影片区压在磨砂层上；
- 电影/电视剧列表页使用首条内容的虚化背景；
- 排序/筛选菜单隐藏系统下拉箭头；
- 主内容、详情、侧边栏使用自绘滚动条：滚动时浮现、停止约 0.9 秒后淡出；
- 详情页选集区在 macOS 直接浮在模糊背景上；
- 设置页为卡片概览 + 详情；右上「更多」只显示三个点。

### iPad

- 顶栏左侧一级栏目下拉、中间分类胶囊、右侧搜索/更多，均无外框；
- 继续观看/电影/电视剧的搜索收进「…」菜单；
- 偏好页不提供搜索；
- 首页头图约 0.62 屏高，底部约露一排半卡片；
- 电视剧详情头图更高，选集模块轻磨砂；
- 季度选择全宽展示；放不下才出现左右箭头，箭头滚动列表；
- 详情/轮播版式已按真机横竖屏调过。

### iPhone

保持 4 个 Tab、页面内搜索与分类入口，不套用 iPad 顶栏改动。

---

## 3. NAS 共享库

设计细节：[Docs/NAS_SHARED_LIBRARY.md](Docs/NAS_SHARED_LIBRARY.md)

每个可写媒体源（本地文件夹 / WebDAV）根目录：

```
.lumen-cache/library-metadata.json   刮削 catalog（可覆盖）
.lumen-cache/library-state.json      观看进度 + 收藏（可覆盖）
```

- 扫描时先导入 catalog；完整条目（类型 + 简介 + 海报）直接跳过 TMDB；
- 不完整条目仍由 TMDB 补齐；
- 写入前先读已有文件合并，保留另一台设备已刮好的条目；
- 收藏取消写 `favorite:false + updatedAt`，按时间戳互相删除；
- 本机 `favorites-stamps.json` 保存收藏修改时间，不写 NAS；
- 设置 → 同步：「元数据写入媒体源」「观看进度 / 收藏写入媒体源」，默认开启；
- 播放中约 15 秒合并写，关闭播放器/进后台 flush；元数据 2 秒合并窗口；
- App 回前台、设置「立即同步」时重新拉取共享状态；
- 不写密码 / TMDB Key / 书签。

限制：

- 进度清除暂无 tombstone；
- 多设备同时写是 last-writer-wins（有先读再合并，但没有文件锁/ETag 重试）；
- 共享格式是 Lumen JSON，不是 Kodi/Emby 直接识别的 NFO；
- Emby/Jellyfin、只读 HTTP 源跳过。

---

## 4. 签名与钥匙串

- 本机 `/Applications/Lumen.app` 当前是**开发证书签名 Debug 版**（Team `WZ6AS9TRW2`），用于复用旧钥匙串；
- 便携 zip 是 **ad-hoc 签名 Release**；其他机器上签名不同，钥匙串不会复用，首次需要输入一次凭据；
- 旧的 ad-hoc 便携版覆盖安装到本机时，会因签名不同重新弹钥匙串授权；点「始终允许」后该签名稳定；
- 不要用 `CODE_SIGNING_ALLOWED=NO` 构建本机日常使用的 macOS App，否则每次构建都可能重弹钥匙串；
- 更换签名/重建便携包后钥匙串提示是 macOS 的 ACL 行为，不是应用重复读取。

---

## 5. 构建与验证

### 工程

```bash
cd /Users/consynia/AI_Project/Lumen
xcodegen generate
```

### macOS（本机，签名）

```bash
xcodebuild -project Lumen.xcodeproj -scheme Lumen-macOS -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/dd-mac build
```

不要加 `CODE_SIGNING_ALLOWED=NO`。

### macOS 便携 ad-hoc

Release + sandbox entitlements + `CODE_SIGN_IDENTITY=-`，产物：

```
dist/0.1.5/Lumen-0.1.5-macOS-arm64-adhoc-2a9dc78.zip
dist/0.1.5/临时使用说明.txt
```

其他机器首次打开需要右键 → 打开，或：

```bash
xattr -dr com.apple.quarantine /Applications/Lumen.app
```

仅 Apple Silicon；未公证。

### iOS 构建 / 测试

```bash
xcodebuild test -project Lumen.xcodeproj -scheme Lumen-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath /tmp/dd-tests \
  -only-testing:Lumen-UnitTests \
  -only-testing:Lumen-iOS-UITests/LibraryNavigationTests \
  CODE_SIGNING_ALLOWED=NO
```

已知：`testCarouselSwipeAndRotation` 在模拟器上是历史旋转时序失败。

### iPad 真机

```bash
./Tools/install-ipad.sh EB06D667-D31C-581C-8061-4C77CC47B395
```

安装成功但启动被拒时通常是 iPad 锁屏（`SBMainWorkspace ... Locked`），解锁后手动打开即可。

---

## 6. 待办 / 已知问题

1. **电视剧“每季卡片下移紫色高度一半”**：尚未精确落位，需要一张电视剧页截图并圈出“紫色高度”指哪块。
2. **设置概览存储占用**：目前用「已刮削」替代，设计稿的存储用量统计尚未实现。
3. **进度清除 tombstone**：清空进度不会删除其它设备共享记录。
4. **共享冲突**：无文件锁/ETag 重试；多设备并发写最后写者覆盖。
5. **NFO 导出**：如需跨 Kodi/Emby 共享，下一步增加可选 NFO 写回。
6. **共享状态不是实时推送**：其它设备在启动/扫描/回前台/手动同步时拉取，不做后台轮询。
7. **macOS 截图权限**：当前终端没有屏幕录制权限，无法自动截 macOS 窗口。

---

## 7. 关键文件

| 文件 | 作用 |
|---|---|
| `Sources/App/LumenApp.swift` | 入口、macOS 侧边栏/窗口、iPad 一级栏目与顶栏 |
| `Sources/UI/HomeView.swift` | 首页/电影/电视剧/偏好、Hero、顶栏、滚动条 |
| `Sources/UI/DetailView.swift` | 详情、头图、选集、季度选择、演职人员 |
| `Sources/UI/SettingsView.swift` | 设置概览 + 详情、同步开关、统计卡 |
| `Sources/UI/PlayerView.swift` | 播放器、外挂字幕、字幕背景 |
| `Sources/Core/Store.swift` | 媒体库、进度/收藏、收藏时间戳、扫描导入 |
| `Sources/Core/SharedLibrarySync.swift` | 共享 catalog/state 模型、合并、调度 |
| `Sources/Core/Metadata.swift` | TMDB、共享元数据导入、分类 |
| `Sources/Core/Sources.swift` | 媒体源、`writeShared` 可覆盖写 |
| `Sources/Core/Subtitles.swift` | SRT/ASS/VTT、语言后缀 |
| `Docs/NAS_SHARED_LIBRARY.md` | 共享库设计/限制 |
| `Tests/Unit/SharedLibrarySyncTests.swift` | 共享模型与本地覆盖写测试 |

---

## 8. 交接检查清单

- [ ] 改 `project.yml` 后执行 `xcodegen generate`
- [ ] macOS 日常使用用签名构建，不要 `CODE_SIGNING_ALLOWED=NO`
- [ ] 共享状态改动后同时跑 UnitTests（含 SharedLibrarySyncTests）和 iPad UI 测试
- [ ] 便携包是 ad-hoc：提醒右键打开 / 去 quarantine / 仅 Apple Silicon
- [ ] iPad 安装后若启动失败，先确认设备解锁
- [ ] 改 iPad 顶栏时确认 iPhone 仍保留页面内搜索
- [ ] 演员页不要重新引入全库扫描，避免 NAS 性能问题
- [ ] 提交前工作区干净并推送 `origin/main`

---

## 9. 仓库

```
git@github.com:chaosdancing/Lumen.git
```
