import SwiftUI

// MARK: - 设置窗口（顶部图标标签栏 + 居中右对齐表单 + 绿色方形勾选）

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var metaStore = MetadataStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var route: SettingsTab?
    @State private var search = ""

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
            case .general:  return "gearshape.fill"
            case .sources:  return "externaldrive.fill"
            case .sync:     return "icloud.fill"
            case .playback: return "play.circle.fill"
            case .playerUI: return "rectangle.on.rectangle"
            case .subtitle: return "captions.bubble.fill"
            case .privacy:  return "lock.shield.fill"
            }
        }

        var gradient: [Color] {
            switch self {
            case .general:
                return [Color(white: 0.58), Color(white: 0.40)]
            case .sources:
                return [Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.0, green: 0.40, blue: 0.84)]
            case .sync:
                return [Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.0, green: 0.56, blue: 1.0)]
            case .playback:
                return [Color(red: 0.20, green: 0.78, blue: 0.35), Color(red: 0.12, green: 0.62, blue: 0.27)]
            case .playerUI:
                return [Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 0.54, green: 0.27, blue: 0.67)]
            case .subtitle:
                return [Color(red: 1.0, green: 0.58, blue: 0.0), Color(red: 1.0, green: 0.42, blue: 0.0)]
            case .privacy:
                return [Color(red: 1.0, green: 0.23, blue: 0.19), Color(red: 0.84, green: 0.0, blue: 0.08)]
            }
        }
    }

    var body: some View {
        ZStack {
            settingsBackground.ignoresSafeArea()
            if let route {
                detail(route)
            } else {
                overview
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 820, maxWidth: 900, minHeight: 560, idealHeight: 620)
        #endif
    }

    // MARK: 外观

    private var settingsBackground: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(red: 0.96, green: 0.96, blue: 0.965)
    }
    private var cardBackground: Color {
        colorScheme == .dark ? Color(white: 0.17) : .white
    }
    private var controlBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }
    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }

    // MARK: 概览

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                searchField
                stats
                Text("偏好设置")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.leading, 4)
                    .padding(.top, 2)

                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 10) {
                    ForEach(filteredTabs) { item in
                        settingCard(item)
                    }
                }

                if filteredTabs.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass",
                                   title: "没有匹配的设置",
                                   message: "换个关键词试试，例如「播放」「字幕」「iCloud」。",
                                   actionTitle: nil, action: nil)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }

                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("设置")
                .font(.system(size: 21, weight: .bold))
            Spacer()
            Button {
                prefs.appearance = colorScheme == .dark ? "light" : "dark"
            } label: {
                Label(colorScheme == .dark ? "浅色" : "深色",
                      systemImage: colorScheme == .dark ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(controlBackground, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("搜索设置…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 360)
    }

    private var stats: some View {
        LazyVGrid(columns: statColumns, spacing: 10) {
            statCard(label: "媒体库",
                     value: "\(store.library.count)",
                     sub: "部影片 · \(store.sources.count) 个源",
                     progress: nil)
            statCard(label: "已刮削",
                     value: "\(metaStore.items.count)",
                     sub: "共 \(store.library.count) 部 · 待刮削 \(max(0, store.library.count - metaStore.items.count))",
                     progress: store.library.isEmpty ? nil : Double(metaStore.items.count) / Double(store.library.count))
            statCard(label: "iCloud 同步",
                     value: store.iCloudProgressAvailable ? "已开启" : "未登录",
                     sub: store.iCloudProgressAvailable ? "进度自动同步" : "进度仅保存在本机",
                     progress: nil)
        }
    }

    private func statCard(label: String, value: String, sub: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(3, geo.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 4)
                .padding(.vertical, 2)
            }
            Text(sub)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(cardBorder, lineWidth: 0.5)
        }
    }

    private func settingCard(_ item: SettingsTab) -> some View {
        Button {
            route = item
        } label: {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: item.gradient,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(summary(for: item))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(cardBorder, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(versionText)
            Spacer()
            Text("无遥测 · 无上报")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.top, 10)
    }

    // MARK: 详情

    private func detail(_ item: SettingsTab) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    route = nil
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(controlBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(item.title)
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Color.clear.frame(width: 62, height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 0) {
                    pane(for: item)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(cardBorder, lineWidth: 0.5)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func pane(for item: SettingsTab) -> some View {
        switch item {
        case .general:  GeneralPane()
        case .sources:  SourcesPane()
        case .sync:     SyncPane()
        case .playback: PlaybackPane()
        case .playerUI: PlayerUIPane()
        case .subtitle: SubtitlePane()
        case .privacy:  PrivacyPane()
        }
    }

    // MARK: 数据

    private var filteredTabs: [SettingsTab] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(q) || summary(for: $0).localizedCaseInsensitiveContains(q)
        }
    }

    private var statColumns: [GridItem] {
        #if os(macOS)
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        #else
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: DeviceInfo.isPad ? 3 : 1)
        #endif
    }

    private var cardColumns: [GridItem] {
        #if os(macOS)
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
        #else
        if DeviceInfo.isPad { return Array(repeating: GridItem(.flexible(), spacing: 10), count: 2) }
        return [GridItem(.flexible())]
        #endif
    }

    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.appVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, !build.isEmpty { return "Lumen \(short) (Build \(build))" }
        return "Lumen \(short)"
    }

    private func summary(for item: SettingsTab) -> String {
        switch item {
        case .general:
            return "显示模式：\(appearanceLabel) · \(languageLabel) · \(sortLabel)排序"
        case .sources:
            return "\(store.sources.count) 个媒体源 · 已刮削 \(metaStore.items.count) / \(store.library.count)"
        case .sync:
            return store.iCloudProgressAvailable ? "iCloud 已启用 · 进度自动同步" : "iCloud 未启用 · 进度仅在本机"
        case .playback:
            return "续播\(prefs.resumePlayback ? "开启" : "关闭") · \(String(format: "%.2fx", prefs.defaultRate)) · 快进 \(Int(prefs.forwardInterval)) 秒"
        case .playerUI:
            return "双击暂停 · 控制层 \(String(format: "%.1f", prefs.autoHideControls)) 秒后隐藏"
        case .subtitle:
            return "\(subtitleColorLabel) · \(Int(prefs.subtitleScale * 100))% · 描边 \(String(format: "%.1f", prefs.subtitleOutline)) · 距底 \(Int(prefs.subtitleBottomInset))"
        case .privacy:
            return "无遥测 · 凭据存钥匙串"
        }
    }

    private var appearanceLabel: String {
        switch prefs.appearance {
        case "light": return "浅色"
        case "dark":  return "深色"
        default:      return "自动"
        }
    }

    private var languageLabel: String {
        switch TMDBClient.language {
        case "zh-CN": return "简体中文"
        case "zh-TW": return "繁體中文"
        case "en-US": return "English"
        case "ja-JP": return "日本語"
        default:      return TMDBClient.language
        }
    }

    private var sortLabel: String {
        switch prefs.defaultSort {
        case "title":  return "名称"
        case "year":   return "年份"
        case "rating": return "评分"
        default:       return "添加日期"
        }
    }

    private var subtitleColorLabel: String {
        switch prefs.subtitleColor {
        case "yellow": return "黄色"
        case "cyan":   return "青色"
        default:       return "白色"
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
        HStack(alignment: .center, spacing: 14) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
            }
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.30)
        }
    }
}

/// VidHub 那种绿色方形勾选：开=绿底白勾，关=灰底
struct CheckBox: View {
    let isOn: Bool
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(isOn ? Color.green : Color.primary.opacity(0.18))
                .frame(width: 40, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .padding(2)
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: isOn)
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
