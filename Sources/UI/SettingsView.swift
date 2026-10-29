import SwiftUI

// MARK: - 设置窗口（顶部图标标签栏 + 居中右对齐表单 + 绿色方形勾选）

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var prefs = Preferences.shared
    @State private var tab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, sources, sync, playback, playerUI, subtitle, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:  return "通用"
            case .sources:  return "资源"
            case .sync:     return "同步"
            case .playback: return "播放"
            case .playerUI: return "播放器界面"
            case .subtitle: return "字幕和音轨"
            case .privacy:  return "隐私与安全"
            }
        }

        var symbol: String {
            switch self {
            case .general:  return "gearshape"
            case .sources:  return "externaldrive"
            case .sync:     return "arrow.triangle.2.circlepath"
            case .playback: return "play.circle"
            case .playerUI: return "rectangle.inset.filled"
            case .subtitle: return "captions.bubble"
            case .privacy:  return "lock.shield"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.35)
            ScrollView {
                VStack(spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, idealWidth: 780, maxWidth: 880, minHeight: 480, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    // MARK: 顶部标签栏

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .regular))
                        Text(item.title)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .foregroundStyle(tab == item ? Color.green : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tab == item ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:  GeneralPane()
        case .sources:  SourcesPane()
        case .sync:     SyncPane()
        case .playback: PlaybackPane()
        case .playerUI: PlayerUIPane()
        case .subtitle: SubtitlePane()
        case .privacy:  PrivacyPane()
        }
    }
}

// MARK: - 通用行容器
/// VidHub 的排版：标签右对齐，控件跟在右侧，整块在窗口里居中。
struct PrefRow<Control: View>: View {
    let label: String
    var labelWidth: CGFloat = 176
    @ViewBuilder var control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 176, alignment: .trailing)
                .padding(.top, 3)
            control()
                .frame(width: 400, alignment: .leading)
        }
        .frame(width: 590, alignment: .leading)
        VStack(alignment: .leading, spacing: 8) {
            if !label.isEmpty {
                Text(label).font(.system(size: 13, weight: .medium))
            }
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .frame(maxWidth: 650, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// VidHub 那种绿色方形勾选：开=绿底白勾，关=灰底
struct CheckBox: View {
    let isOn: Bool
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Color.green : Color.primary.opacity(0.18))
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 19, height: 19)

            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}

/// 深色圆角弹出选择器外观
struct PrefPicker<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            EmptyView()
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var language = TMDBClient.language

    var body: some View {
        VStack(spacing: 0) {
            PrefRow(label: "轮播图") {
                Button { prefs.showCarousel.toggle() } label: {
                    CheckBox(isOn: prefs.showCarousel, caption: prefs.showCarousel ? "显示" : "隐藏")
                }
                .buttonStyle(.plain)
            }

            PrefRow(label: "剧透") {
                Button { prefs.hideSpoilers.toggle() } label: {
                    CheckBox(isOn: prefs.hideSpoilers, caption: prefs.hideSpoilers ? "隐藏" : "显示")
                }
                .buttonStyle(.plain)
            }

            PrefRow(label: "评分角标") {
                Button { prefs.showRatings.toggle() } label: {
                    CheckBox(isOn: prefs.showRatings, caption: prefs.showRatings ? "显示" : "隐藏")
                }
                .buttonStyle(.plain)
            }

            PrefRow(label: "更多评分") {
                Text("暂不支持其他评分来源").font(.caption).foregroundStyle(.secondary)
            }

            PrefRow(label: "排序方式:") {
                Picker("", selection: $prefs.defaultSort) {
                    Label("添加日期", systemImage: "arrow.down").tag("added")
                    Text("名称").tag("title")
                    Text("年份").tag("year")
                    Text("评分").tag("rating")
                }
                .labelsHidden()
                .frame(width: 190)
            }

            PrefRow(label: "外观:") {
                Picker("", selection: $prefs.appearance) {
                    Text("跟随系统").tag("auto")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .labelsHidden()
                .frame(width: 190)
            }

            PrefRow(label: "在线影视数据语言:", labelWidth: 150) {
                Picker("", selection: $language) {
                    Text("自动").tag("auto")
                    Text("简体中文").tag("zh-CN")
                    Text("繁體中文").tag("zh-TW")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }
                .labelsHidden()
                .frame(width: 190)
                .onChange(of: language) { _, newValue in
                    TMDBClient.setLanguage(newValue == "auto" ? "zh-CN" : newValue)
                }
            }

            PrefRow(label: "优先使用本地海报图片:", labelWidth: 150) {
                Button { prefs.preferLocalPoster.toggle() } label: {
                    CheckBox(isOn: prefs.preferLocalPoster,
                             caption: prefs.preferLocalPoster ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }

            PrefRow(label: "优先使用NFO文件影视数据:", labelWidth: 150) {
                Button { prefs.preferNFO.toggle() } label: {
                    CheckBox(isOn: prefs.preferNFO, caption: prefs.preferNFO ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 资源

private struct SourcesPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metaStore = MetadataStore.shared

    @State private var keyText = TMDBClient.apiKey ?? ""
    @State private var showKey = false
    @State private var scraping = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.sources) { source in
                PrefRow(label: source.name, labelWidth: 150) {
                    HStack(spacing: 8) {
                        Text("\(store.library.filter { $0.sourceID == source.id }.count) 个条目")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("扫描") { Task { await store.scan(source) } }
                            .controlSize(.small)
                    }
                }
            }
            if store.sources.isEmpty {
                PrefRow(label: "媒体源", labelWidth: 150) {
                    Text("还没有添加").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Divider().frame(maxWidth: 620).padding(.vertical, 12)

            PrefRow(label: "TMDB API Key", labelWidth: 150) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                    if showKey {
                        TextField("v3 auth", text: $keyText)
                    } else {
                        SecureField("v3 auth", text: $keyText)
                    }
                    Button { showKey.toggle() } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    }
                    Button("保存") {
                        message = TMDBClient.setAPIKey(keyText.trimmingCharacters(in: .whitespacesAndNewlines))
                            ? "已保存" : "钥匙串保存失败，请检查应用签名"
                    }
                    .controlSize(.small)
                }
            }

            PrefRow(label: "刮削", labelWidth: 150) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await scrape() }
                    } label: {
                        if scraping { ProgressView().controlSize(.small) } else { Text("开始刮削") }
                    }
                    .controlSize(.small)
                    .disabled(scraping || TMDBClient.apiKey == nil)

                    Text("已刮削 \(metaStore.items.count) / \(store.library.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }

            PrefRow(label: "", labelWidth: 150) {
                Text("在 themoviedb.org 免费申请 API Key。没有 Key 时只读片源目录里的 .nfo / poster.jpg。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scrape() async {
        scraping = true
        let targets = store.movieItems + store.seriesGroups.compactMap(\.posterItem)
        await metaStore.scrapeAll(items: targets, in: store, limit: 300)
        scraping = false
        message = "完成"
    }
}

// MARK: - 同步（无账号体系）

private struct SyncPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: store.iCloudProgressAvailable ? "icloud" : "icloud.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(store.iCloudProgressAvailable ? Color.green : Color.secondary)
            Text(store.iCloudProgressAvailable ? "观看记录已接入 iCloud" : "iCloud 观看记录暂不可用")
                .font(.system(size: 13, weight: .medium))
            Text("播放进度先保存在本机，再同步到使用同一 Apple 账户的 Mac 和 iPad。两端需扫描到同一影片；其他资料仍保存在本机。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("立即同步") { store.flushProgressSync() }
                .padding(.top, 8)
        }
        .padding(.top, 60)
    }
}

// MARK: - 播放

private struct PlaybackPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            PrefRow(label: "继续上次播放位置") {
                Button { prefs.resumePlayback.toggle() } label: {
                    CheckBox(isOn: prefs.resumePlayback, caption: prefs.resumePlayback ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
            PrefRow(label: "播完自动标记已观看") {
                Button { prefs.autoMarkWatched.toggle() } label: {
                    CheckBox(isOn: prefs.autoMarkWatched, caption: prefs.autoMarkWatched ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
            PrefRow(label: "窗口最小化时暂停") {
                Button { prefs.pauseOnMinimize.toggle() } label: {
                    CheckBox(isOn: prefs.pauseOnMinimize, caption: prefs.pauseOnMinimize ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
            PrefRow(label: "默认速度:") {
                Picker("", selection: $prefs.defaultRate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Text(String(format: "%.2fx", r)).tag(r)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            PrefRow(label: "快进间隔:") {
                Picker("", selection: $prefs.forwardInterval) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { v in
                        Text("\(Int(v)) 秒").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            PrefRow(label: "快退间隔:") {
                Picker("", selection: $prefs.rewindInterval) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { v in
                        Text("\(Int(v)) 秒").tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            Divider().frame(maxWidth: 620).padding(.vertical, 12)

            ForEach(["硬件加速（VideoToolbox）", "自动消除隔行扫描", "强制使用独立显卡", "缓存到磁盘"], id: \.self) { item in
                PrefRow(label: item) {
                    Text("尚未提供此设置")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - 播放器界面

private struct PlayerUIPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            PrefRow(label: "双击画面暂停") {
                Button { prefs.doubleClickPause.toggle() } label: {
                    CheckBox(isOn: prefs.doubleClickPause, caption: prefs.doubleClickPause ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
            PrefRow(label: "控制层自动隐藏:") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.autoHideControls, in: 1...10, step: 0.5)
                        .frame(width: 180)
                    Text(String(format: "%.1f 秒", prefs.autoHideControls))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                }
            }
            PrefRow(label: "截图格式:") {
                Picker("", selection: $prefs.screenshotFormat) {
                    Text("JPEG").tag("jpg")
                    Text("PNG").tag("png")
                }
                .labelsHidden()
                .frame(width: 190)
            }
            PrefRow(label: "截图保存位置") {
                Text(prefs.resolvedScreenshotFolder.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrefRow(label: "海报密度:") {
                Text("自动适应窗口宽度，暂不支持自定义密度")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 字幕和音轨

private struct SubtitlePane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            PrefRow(label: "自动加载同目录字幕") {
                Button { prefs.subtitleAutoLoad.toggle() } label: {
                    CheckBox(isOn: prefs.subtitleAutoLoad, caption: prefs.subtitleAutoLoad ? "开启" : "关闭")
                }
                .buttonStyle(.plain)
            }
            PrefRow(label: "字号:") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.subtitleScale, in: 0.7...2.0, step: 0.05).frame(width: 180)
                    Text(String(format: "%.0f%%", prefs.subtitleScale * 100))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                }
            }
            PrefRow(label: "颜色:") {
                Picker("", selection: $prefs.subtitleColor) {
                    Text("白色").tag("white")
                    Text("黄色").tag("yellow")
                    Text("青色").tag("cyan")
                }
                .labelsHidden()
                .frame(width: 190)
            }
            PrefRow(label: "描边:") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.subtitleOutline, in: 0...4, step: 0.5).frame(width: 180)
                    Text(String(format: "%.1f", prefs.subtitleOutline))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                }
            }
            PrefRow(label: "距底部:") {
                HStack(spacing: 8) {
                    Slider(value: $prefs.subtitleBottomInset, in: 20...160, step: 4).frame(width: 180)
                    Text("\(Int(prefs.subtitleBottomInset))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                }
            }
            PrefRow(label: "音轨") {
                Text("在播放器的音轨菜单中选择；这里暂不提供默认音轨设置")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            // 预览
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black)
                Text("这是一行示例字幕")
                    .font(.system(size: 20 * prefs.subtitleScale, weight: .medium))
                    .foregroundStyle(previewColor)
                    .shadow(color: .black, radius: prefs.subtitleOutline, x: 0, y: 0)
            }
            .frame(maxWidth: 460)
            .frame(height: 92)
            .padding(.top, 18)
        }
    }

    private var previewColor: Color {
        switch prefs.subtitleColor {
        case "yellow": return .yellow
        case "cyan":   return .cyan
        default:       return .white
        }
    }
}

// MARK: - 隐私与安全

private struct PrivacyPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            PrefRow(label: "数据目录") {
                Text(StorePaths.root.path)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrefRow(label: "凭据") {
                Text("账号密码 / API Key 存在钥匙串；DEBUG 构建额外缓存在本地文件（0600）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrefRow(label: "网络") {
                Text("只访问你添加的媒体源与 TMDB；无遥测、无上报")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            PrefRow(label: "清空索引") {
                Button("清空媒体库索引", role: .destructive) { confirmingClear = true }
                    .controlSize(.small)
            }
        }
        .confirmationDialog("清空索引？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { store.removeAllLibrary() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只删 Lumen 自己的索引与播放记录，不动磁盘上的文件。")
        }
    }
}
