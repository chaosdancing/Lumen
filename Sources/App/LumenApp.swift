import SwiftUI

// MARK: - 播放器呈现

@MainActor
final class PlayerPresenter: ObservableObject {
    @Published var item: MediaItem?
    func play(_ item: MediaItem) { self.item = item }
    func close() { item = nil }
}

@main
struct LumenApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()
    @StateObject private var artwork = ArtworkStore()
    /// 外观偏好要在 App 层观察，否则「设置 → 外观」改完不会立刻生效
    @ObservedObject private var prefs = Preferences.shared

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            rootContent
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("扫描全部媒体源") {
                    Task { for s in store.sources { await store.scan(s) } }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // 系统「设置…」（⌘,）
        Settings {
            NavigationStack { SettingsView().environmentObject(store) }
        }
        #else
        WindowGroup {
            rootContent
        }
        #endif
    }

    /// 诊断：容器里放 `scrape-test.flag`（内容为片名），启动时跑一次 TMDB 搜索并把结果写进日志
    private func runScrapeProbeIfRequested() async {
        let flag = StorePaths.root.appendingPathComponent("scrape-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        AppLog.info("PROBE 查询=\(query) 变体=\(TMDBClient.queryVariants(query))")
        guard TMDBClient.apiKey != nil else {
            AppLog.error("PROBE 没有 TMDB key")
            return
        }
        for isSeries in [true, false] {
            do {
                let meta = try await TMDBClient.shared.scrape(itemID: "probe-\(isSeries)",
                                                              query: query,
                                                              year: nil,
                                                              isSeries: isSeries)
                if let meta {
                    AppLog.info("PROBE \(isSeries ? "tv" : "movie") 命中：\(meta.title ?? "-") rating=\(meta.rating ?? 0) genres=\(meta.genres) cast=\(meta.cast.count)")
                } else {
                    AppLog.info("PROBE \(isSeries ? "tv" : "movie") 无结果")
                }
            } catch {
                AppLog.error("PROBE \(isSeries ? "tv" : "movie") 失败：\(error.logDescription)")
            }
        }
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(store)
            .environmentObject(artwork)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.flushProgressSync() }
            }
            #if os(macOS)
            .frame(minWidth: 960, minHeight: 620)
            #endif
            .task {
                AppLog.info("APP 启动 v\(Bundle.main.appVersion) 库=\(store.library.count) 源=\(store.sources.count)")
                await runScrapeProbeIfRequested()
                guard store.library.isEmpty else { return }
                for source in store.sources where source.kind.isAvailable {
                    await store.scan(source)
                }
            }
    }
}

// MARK: - 浏览目标

enum BrowseDestination: Hashable {
    case home
    case continueWatching
    case recentlyAdded
    case movies
    case series
    case search
    case genres
    case years
    case ratings
    case certifications
    case allMedia
    case unwatched
    case watched
    case favorites
    case source(UUID)
    case sourceGroup(isServer: Bool)

    var title: String {
        switch self {
        case .home:             return "媒体库"
        case .continueWatching: return "继续观看"
        case .recentlyAdded:    return "最近添加"
        case .movies:           return "电影"
        case .series:           return "电视剧"
        case .search:           return "搜索"
        case .genres:           return "类型"
        case .years:            return "年代"
        case .ratings:          return "评分"
        case .certifications:   return "分级"
        case .allMedia:         return "全部影视"
        case .unwatched:        return "未观看"
        case .watched:          return "已观看"
        case .favorites:        return "收藏夹"
        case .source:           return "文件源"
        case .sourceGroup(let isServer): return isServer ? "影视服务器" : "文件源"
        }
    }

    var symbol: String {
        switch self {
        case .home:             return "play.rectangle.fill"
        case .continueWatching: return "clock.arrow.circlepath"
        case .recentlyAdded:    return "clock"
        case .movies:           return "film"
        case .series:           return "tv"
        case .search:           return "magnifyingglass"
        case .genres:           return "tag"
        case .years:            return "calendar"
        case .ratings:          return "star"
        case .certifications:   return "checkmark.shield"
        case .allMedia:         return "square.grid.2x2"
        case .unwatched:        return "circle"
        case .watched:          return "checkmark.circle"
        case .favorites:        return "star"
        case .source:           return "folder"
        case .sourceGroup(let isServer): return isServer ? "externaldrive.connected.to.line.below" : "folder"
        }
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    let symbol: String
    let title: String
    var isSelected: Bool
    var indent: CGFloat = 0
    var trailing: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10)
                                     : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.82))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarGroupHeader: View {
    let title: String
    var emoji: String = ""
    @Binding var expanded: Bool
    var selected: Bool = false
    var onTapTitle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if let onTapTitle { onTapTitle() }
                else { withAnimation(.smooth(duration: 0.18)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    if !emoji.isEmpty {
                        Text(emoji).font(.system(size: 13))
                    }
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.75))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - 根视图

/// iPad 顶栏的一级栏目。iPad 上不再使用系统 TabView 顶部分段，而是收进一个下拉菜单。
enum RootSection: String, CaseIterable, Identifiable, Hashable {
    case library, preferences, sources, servers, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "媒体库"
        case .preferences: return "偏好"
        case .sources: return "文件源"
        case .servers: return "服务器"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "play.rectangle.fill"
        case .preferences: return "slider.horizontal.3"
        case .sources: return "folder.fill"
        case .servers: return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }

    var emoji: String {
        switch self {
        case .library: return "🎬"
        case .preferences: return "❤️"
        case .sources: return "📁"
        case .servers: return "🖥️"
        case .settings: return "⚙️"
        }
    }
}

@MainActor
final class AppSectionRouter: ObservableObject {
    @Published var section: RootSection = .library
    /// 再次选择「媒体库」时也回到媒体库首页（即使当前已经在该栏目）。
    @Published var libraryHomeRequest = 0

    func select(_ section: RootSection) {
        if section == .library { libraryHomeRequest &+= 1 }
        self.section = section
    }
}

enum DeviceInfo {
    static var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
}

#if os(iOS)
/// iPad 顶栏的一级栏目下拉：媒体库 / 偏好 / 文件源 / 服务器 / 设置。
/// 用自定义 popover 而不是系统 Menu，才能把选中勾放到行的最右侧。
struct SectionMenu: View {
    @EnvironmentObject private var router: AppSectionRouter
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("\(router.section.emoji) \(router.section.title)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Color.primary.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 11)
                    .rotationEffect(.degrees(showing ? 180 : 0))
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tint(Color.primary)
        .accessibilityLabel("一级栏目：\(router.section.title)")
        .accessibilityHint("切换媒体库、偏好、文件源、服务器和设置")
        .accessibilityIdentifier("app.sections")
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(spacing: 0) {
                ForEach(RootSection.allCases) { section in
                    Button {
                        router.select(section)
                        showing = false
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(section.emoji)  \(section.title)")
                                .font(.system(size: 16))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 24)
                            if router.section == section {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                }
            }
            .frame(width: 232)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct PadSectionToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            if DeviceInfo.isPad {
                ToolbarItem(placement: .topBarLeading) { SectionMenu() }
            }
        }
    }
}

private extension View {
    func padSectionToolbar() -> some View { modifier(PadSectionToolbar()) }
}

#endif

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: BrowseDestination = .home
    @State private var libraryExpanded = true
    @State private var sourcesExpanded = true
    @StateObject private var player = PlayerPresenter()
    @State private var showSettings = false
    @State private var editingSource: MediaSourceConfig?
    @State private var serversExpanded = true
    @Namespace private var selectionNS
    @State private var navPath = NavigationPath()
    @State private var showAddSheet = false
    @State private var newSourcePreset: SourceKind = .webdav
    @ObservedObject private var prefs = Preferences.shared
    @StateObject private var router = AppSectionRouter()

    var body: some View {
        // 外观跟着「设置 → 外观」走：这里必须由 RootView 自己带（它观察了 Preferences），
        // 放在 App 里的话 App 的 body 不会因为偏好变化而重算，切了也不生效
        #if os(macOS)
        platformContent
            .preferredColorScheme(preferredScheme)
            .background(WindowAppearanceSetter(name: appearanceName))
        #else
        platformContent
            .preferredColorScheme(preferredScheme)
            .task {
                // 诊断入口：容器里放 section-test.flag / shot.flag 才生效，
                // 用于无触摸环境切栏目并截图核对版式。
                applySectionTestIfRequested()
                await DebugProbes.captureWindowIfRequested()
            }
        #endif
    }

    private var preferredScheme: ColorScheme? {
        switch prefs.appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    #if os(macOS)
    private var appearanceName: NSAppearance.Name? {
        switch prefs.appearance {
        case "dark":  return .darkAqua
        case "light": return .aqua
        default:      return nil
        }
    }
    #endif

    @ViewBuilder
    private var platformContent: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 222, max: 260)
        } detail: {
            NavigationStack(path: $navPath) {
                content
                    .detailDestinations()
            }
        }
        .environmentObject(player)
        .onChange(of: player.item) { _, newValue in
            if let item = newValue {
                PlayerWindowController.shared.show(
                    PlayerView(item: item)
                        .environmentObject(store)
                        .environmentObject(player),
                    title: item.seriesTitle ?? item.title,
                    onClose: { player.item = nil }
                )
            } else {
                PlayerWindowController.shared.close()
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showSettings = false }
                        }
                    }
            }
        }
        .task {
            runSelfTestIfRequested()
            selectPageIfRequested()
            await openDetailIfRequested()
            await openPlayerIfRequested()
            await DebugProbes.captureWindowIfRequested()
        }
        .onAppear { applyAppearance() }
        .onChange(of: prefs.appearance) { _, _ in applyAppearance() }
        #else
        Group {
            // iPad：不再使用系统 TabView 的顶部分段，改为顶栏下拉 + 单一内容区。
            if DeviceInfo.isPad {
                padRoot
            } else {
                TabView(selection: $router.section) {
                    BrowseTab(destination: .home)
                        .tabItem { Label("媒体库", systemImage: "play.rectangle.fill") }
                        .tag(RootSection.library)

                    NavigationStack {
                        SourceGroupView(isServer: false)
                    }
                    .tabItem { Label("文件源", systemImage: "folder.fill") }
                    .tag(RootSection.sources)

                    NavigationStack {
                        SourceGroupView(isServer: true)
                    }
                    .tabItem { Label("服务器", systemImage: "server.rack") }
                    .tag(RootSection.servers)

                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(RootSection.settings)
                }
            }
        }
        .environmentObject(player)
        .environmentObject(router)
        .fullScreenCover(item: $player.item) { item in
            PlayerView(item: item)
                .environmentObject(store)
                .environmentObject(player)
        }
        .task {
            // 诊断：容器里放 play-test.flag（内容为库内相对路径）→ 启动后直接播这一条
            let flag = StorePaths.root.appendingPathComponent("play-test.flag")
            guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: flag)
            let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let item = store.library.first(where: { $0.path == target }) {
                AppLog.info("PLAY TEST 播放 \(item.path.suffix(40))")
                player.play(item)
            } else {
                AppLog.error("PLAY TEST 找不到条目：\(target)")
            }
        }
        #endif
    }

    #if os(iOS)
    /// DEBUG 诊断：把 section-test.flag 的内容当作栏目名，启动后直接切过去。
    private func applySectionTestIfRequested() {
        #if DEBUG
        let flag = StorePaths.root.appendingPathComponent("section-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "library":     router.section = .library
        case "preferences": router.section = .preferences
        case "sources":     router.section = .sources
        case "servers":     router.section = .servers
        case "settings":    router.section = .settings
        default:            break
        }
        #endif
    }

    /// iPad 根视图：四个一级栏目共用一个内容区，栏目切换收进顶栏下拉菜单。
    @ViewBuilder private var padRoot: some View {
        switch router.section {
        case .library:
            BrowseTab(destination: .home)
        case .preferences:
            PreferencesTab()
        case .sources:
            NavigationStack {
                SourceGroupView(isServer: false)
                    .padSectionToolbar()
            }
        case .servers:
            NavigationStack {
                SourceGroupView(isServer: true)
                    .padSectionToolbar()
            }
        case .settings:
            NavigationStack {
                SettingsView()
                    .padSectionToolbar()
            }
        }
    }
    #endif

    // MARK: 侧边栏

    #if os(macOS)
    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // 媒体库：点标题回首页
                    SidebarGroupHeader(title: "媒体库", emoji: "🎬",
                                       expanded: $libraryExpanded,
                                       selected: isLibrarySelection,
                                       onTapTitle: { select(.home) })
                    if libraryExpanded {
                        ForEach([BrowseDestination.continueWatching, .recentlyAdded,
                                 .movies, .series, .genres, .years,
                                 .ratings, .certifications,
                                 .unwatched, .watched, .favorites],
                                id: \.self) { dest in
                            sidebarRow(symbol: dest.symbol, title: dest.title,
                                       selected: selection == dest) {
                                select(dest)
                            }
                        }
                    }

                    // 文件源
                    SidebarGroupHeader(title: "文件源", emoji: "📁",
                                       expanded: $sourcesExpanded,
                                       selected: selection == .sourceGroup(isServer: false),
                                       onTapTitle: { select(.sourceGroup(isServer: false)) })
                        .padding(.top, 12)
                    if sourcesExpanded {
                        let fileSources = store.sources.filter { !$0.kind.isMediaServer }
                        ForEach(fileSources) { source in
                            sourceRow(source)
                        }
                        if fileSources.isEmpty {
                            Text("还没有添加")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 30)
                                .padding(.vertical, 3)
                        }
                    }

                    // 影视服务器
                    SidebarGroupHeader(title: "影视服务器", emoji: "🖥️",
                                       expanded: $serversExpanded,
                                       selected: selection == .sourceGroup(isServer: true),
                                       onTapTitle: { select(.sourceGroup(isServer: true)) })
                        .padding(.top, 12)
                    if serversExpanded {
                        let servers = store.sources.filter { $0.kind.isMediaServer }
                        ForEach(servers) { source in
                            sourceRow(source)
                        }
                        if servers.isEmpty {
                            Text("Emby / Jellyfin")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 30)
                                .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .animation(.smooth(duration: 0.22), value: libraryExpanded)
                .animation(.smooth(duration: 0.22), value: sourcesExpanded)
                .animation(.smooth(duration: 0.22), value: serversExpanded)
            }

            bottomCard
        }
        .background {
            Rectangle().fill(.regularMaterial)
                .overlay(Color.black.opacity(0.10))
        }
        .sheet(item: $editingSource) { source in
            AddSourceSheet(editing: source).environmentObject(store)
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(presetKind: newSourcePreset).environmentObject(store)
        }
    }

    #endif

    // MARK: 侧边栏行

    private func sidebarRow(symbol: String, title: String, selected: Bool,
                            trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 17)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).font(.system(size: 14))
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .matchedGeometryEffect(id: "sel", in: selectionNS)
                }
            }
        }
        .buttonStyle(SidebarRowButtonStyle())
    }

    /// 文件源/服务器行：整行悬停就露出「…」菜单（编辑/扫描/删除）
    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        SourceSidebarRow(
            source: source,
            count: store.library.filter { $0.sourceID == source.id }.count,
            selected: selection == .source(source.id),
            namespace: selectionNS,
            onOpen: {
                navPath = NavigationPath()
                selection = .source(source.id)
                logClick(source.name)
            },
            onEdit: { editingSource = source },
            onScan: { Task { await store.scan(source) } },
            onDelete: { store.removeSource(source.id) }
        )
    }

    /// 「+ 添加文件源 / 添加影视服务器」入口
    private func addRow(title: String, preset: SourceKind) -> some View {
        Button {
            newSourcePreset = preset
            editingSource = nil
            showAddSheet = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 17)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.vertical, 5.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }

    private var bottomCard: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25)
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape").font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("设置").font(.system(size: 12.5, weight: .medium))
                        Text("\(store.library.count) 条目 · \(store.sources.count) 源")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    // MARK: 内容

    /// 侧边栏优先级最高：先清空导航栈再切换，避免停在某个详情页出不来
    private func select(_ dest: BrowseDestination) {
        navPath = NavigationPath()
        selection = dest
        logClick(dest.title)
    }

    private var isLibrarySelection: Bool {
        switch selection {
        case .source, .sourceGroup: return false
        default: return true
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .source(let id):
            if let src = store.source(for: id) {
                FileBrowserView(source: src)
            } else {
                EmptyStateView(symbol: "questionmark.folder", title: "源已删除",
                               message: "这个媒体源不存在了。", actionTitle: nil, action: nil)
            }
        case .sourceGroup(let isServer):
            SourceGroupView(isServer: isServer)
        case .search:
            LibrarySearchView()
        case .years:
            LibraryCategoryView(kind: .years)
        case .genres:
            LibraryCategoryView(kind: .genres)
        case .ratings:
            LibraryCategoryView(kind: .ratings)
        case .certifications:
            LibraryCategoryView(kind: .certifications)
        default:
            BrowseView(destination: selection) { select($0) }
        }
    }

    // MARK: 外观

    /// 「设置 → 外观」：跟随系统 / 浅色 / 深色。
    /// SwiftUI 的 preferredColorScheme 在 macOS 上对已有窗口生效得慢，
    /// 这里同时改 NSApp.appearance，切换是立刻的（播放器窗口自己强制深色，不受影响）。
    private func applyAppearance() {
        #if os(macOS)
        switch prefs.appearance {
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default:      NSApp.appearance = nil
        }
        #endif
    }

    // MARK: 诊断

    private func logClick(_ label: String) {
        let url = StorePaths.root.appendingPathComponent("click.log")
        let line = "\(Date().formatted(date: .omitted, time: .standard))  tapped \(label)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func runSelfTestIfRequested() {
        let flag = StorePaths.root.appendingPathComponent("selftest.flag")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        try? FileManager.default.removeItem(at: flag)

        let path = StorePaths.root.appendingPathComponent("selftest.txt")
        let text = "SELFTEST v\(Bundle.main.appVersion)\nselection=\(selection.title)\n"
        try? text.write(to: path, atomically: true, encoding: .utf8)
    }

    /// 诊断：容器里放 `page-test.flag`（home / recent / movies / series / favorites …）→ 启动后切到该页
    private func selectPageIfRequested() {
        let flag = StorePaths.root.appendingPathComponent("page-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "home":      selection = .home
        case "recent":    selection = .recentlyAdded
        case "continue":  selection = .continueWatching
        case "movies":    selection = .movies
        case "series":    selection = .series
        case "genres":    selection = .genres
        case "years":     selection = .years
        case "ratings":   selection = .ratings
        case "certifications": selection = .certifications
        case "unwatched": selection = .unwatched
        case "watched":   selection = .watched
        case "favorites": selection = .favorites
        default: break
        }
    }

    /// 诊断：容器里放 `detail-test.flag`（内容为片名或库内相对路径）→ 启动后直接进详情页，
    /// 方便截图核对头图版式（不影响正常启动）
    private func openDetailIfRequested() async {
        let flag = StorePaths.root.appendingPathComponent("detail-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        for _ in 0..<40 where store.library.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let series = store.seriesGroups.first(where: { $0.title.contains(target) }) {
            AppLog.info("DETAIL TEST 打开剧集 \(series.title)")
            navPath.append(DetailTarget.series(series))
        } else if let movie = store.library.first(where: { $0.path == target || $0.title.contains(target) }) {
            AppLog.info("DETAIL TEST 打开电影 \(movie.title)")
            navPath.append(DetailTarget.movie(movie))
        } else {
            AppLog.error("DETAIL TEST 找不到条目：\(target)")
        }
    }

    /// 诊断：容器里放 `play-test.flag`（内容为片名或库内相对路径）→ 启动后直接开播放器窗口
    private func openPlayerIfRequested() async {
        let flag = StorePaths.root.appendingPathComponent("play-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        for _ in 0..<40 where store.library.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let item = store.library.first(where: { $0.path == target || $0.title.contains(target) }) {
            AppLog.info("PLAY TEST 播放 \(item.title)")
            player.play(item)
        } else {
            AppLog.error("PLAY TEST 找不到条目：\(target)")
        }
    }
}

// MARK: - 窗口外观

#if os(macOS)
/// 直接把主窗口的 appearance 设掉。
/// SwiftUI 的 `preferredColorScheme` 在 macOS 上遇到 NavigationSplitView 时经常不落到窗口上，
/// 这里用 NSView 反查自己所在的窗口，最直接也最可靠（播放器窗口有自己的深色设置，不受影响）。
/// SwiftUI 的 scrollIndicators 在部分 macOS 版本不会真正移除 NSScroller，
/// 这里直接关掉所在 NSScrollView 的滚动条，只保留自绘胶囊。
private struct SidebarScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            var parent = view.superview
            while let node = parent {
                if let scroll = node as? NSScrollView {
                    scroll.hasVerticalScroller = false
                    scroll.verticalScroller = nil
                    break
                }
                parent = node.superview
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SidebarScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct SidebarScrollMetricsKey: PreferenceKey {
    static var defaultValue = SidebarScrollMetrics()
    static func reduce(value: inout SidebarScrollMetrics, nextValue: () -> SidebarScrollMetrics) {
        value = nextValue()
    }
}

/// 侧边栏自己的滚动条：隐藏系统 overlay scrollbar，按内容比例画一条细胶囊。
private struct SidebarScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrolling = false
    @State private var scrollGeneration = 0

    var body: some View {
        ScrollView {
            content
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: SidebarScrollMetricsKey.self,
                            value: SidebarScrollMetrics(
                                offset: geo.frame(in: .named("sidebar.scroll")).minY,
                                contentHeight: geo.size.height
                            )
                        )
                    }
                }
        }
        .coordinateSpace(name: "sidebar.scroll")
        .scrollIndicators(.never)
        .background { SidebarScrollerHider() }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in viewportHeight = height }
            }
        }
        .onPreferenceChange(SidebarScrollMetricsKey.self) { metrics in
            let moved = abs(metrics.offset - offset) > 0.2
            offset = metrics.offset
            contentHeight = metrics.contentHeight
            if moved {
                if !scrolling {
                    withAnimation(.easeOut(duration: 0.12)) { scrolling = true }
                }
                scrollGeneration += 1
                let generation = scrollGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard generation == scrollGeneration else { return }
                    withAnimation(.easeOut(duration: 0.35)) { scrolling = false }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            GeometryReader { geo in
                let track = geo.size.height
                if contentHeight > viewportHeight + 1, viewportHeight > 0, track > 0 {
                    let thumb = max(28, track * viewportHeight / contentHeight)
                    let maxScroll = max(1, contentHeight - viewportHeight)
                    let progress = min(1, max(0, -offset / maxScroll))
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(Color.primary.opacity(0.34))
                            .frame(width: 5, height: thumb)
                            .offset(y: progress * (track - thumb))
                            .opacity(scrolling ? 1 : 0)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 3)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.2), value: scrolling)
                }
            }
        }
    }
}

private final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }

    func applyChrome() {
        guard let window else { return }
        // 先于工具栏布局设置全尺寸内容，避免搜索按钮先出现在左上再跳到右上。
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
    }
}

private struct WindowAppearanceSetter: NSViewRepresentable {
    let name: NSAppearance.Name?

    func makeNSView(context: Context) -> NSView { WindowChromeView() }

    func updateNSView(_ view: NSView, context: Context) {
        let target = name.flatMap { NSAppearance(named: $0) }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.appearance !== target { window.appearance = target }
            (view as? WindowChromeView)?.applyChrome()
        }
    }
}
#endif

// MARK: - 侧边栏辅助视图

private struct SidebarRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.14)
                          : (hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
    }
}

private struct SourceSidebarRow: View {
    let source: MediaSourceConfig
    let count: Int
    let selected: Bool
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onScan: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 9) {
                    Image(systemName: source.kind.symbol)
                        .font(.system(size: 12.5))
                        .frame(width: 17)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(source.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !hovering {
                        Text("\(count)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 5.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("编辑…", systemImage: "slider.horizontal.3", action: onEdit)
                Button("重新扫描", systemImage: "arrow.clockwise", action: onScan)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .padding(.trailing, 6)
            .help("编辑这个媒体源")
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.10)
                      : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.smooth(duration: 0.16)) { hovering = h }
        }
        .contextMenu {
            Button("编辑…") { onEdit() }
            Button("重新扫描") { onScan() }
            Button("删除", role: .destructive) { onDelete() }
        }
        .animation(.smooth(duration: 0.2), value: selected)
    }
}


/// 媒体库：首页 + 三个顶栏快捷入口（继续观看 / 电影 / 电视剧）
#if os(iOS)
struct BrowseTab: View {
    let destination: BrowseDestination
    @StateObject private var nav = NavModel()
    @EnvironmentObject private var router: AppSectionRouter
    @State private var selection: BrowseDestination = .home

    /// iPhone 仍用旧的分类菜单；iPad 的栏目切换统一走 SectionMenu。
    private let destinations: [BrowseDestination] = [
        .home, .movies, .series, .recentlyAdded, .continueWatching,
        .genres, .years, .ratings, .certifications, .favorites
    ]

    private let quickDestinations: [BrowseDestination] = [
        .continueWatching, .movies, .series
    ]
    private var showsTopActions: Bool { DeviceInfo.isPad && nav.path.isEmpty }

    private func select(_ destination: BrowseDestination) {
        nav.path = NavigationPath()
        selection = destination
    }

    /// 只有 iPad 根页面显示顶栏搜索；push 出去后隐藏，iPhone 用页面内搜索框
    private var topSearch: (() -> Void)? {
        guard DeviceInfo.isPad, nav.path.isEmpty else { return nil }
        return { nav.open(BrowseRoute.list(.search)) }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .years:
            LibraryCategoryView(kind: .years, onSearch: topSearch, searchIdentifier: "library.search")
        case .genres:
            LibraryCategoryView(kind: .genres, onSearch: topSearch, searchIdentifier: "library.search")
        case .ratings:
            LibraryCategoryView(kind: .ratings, onSearch: topSearch, searchIdentifier: "library.search")
        case .certifications:
            LibraryCategoryView(kind: .certifications, onSearch: topSearch, searchIdentifier: "library.search")
        default:
            BrowseView(destination: selection, onOpenDestination: select,
                       onSearch: topSearch, searchIdentifier: "library.search")
        }
    }

    var body: some View {
        NavigationStack(path: $nav.path) {
            content
                .detailDestinations()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if DeviceInfo.isPad {
                            SectionMenu()
                        } else {
                            Menu {
                                ForEach(destinations, id: \.self) { destination in
                                    Button { select(destination) } label: {
                                        Label(destination.title, systemImage: selection == destination ? "checkmark" : destination.symbol)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(selection.title).font(.headline)
                                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                                .contentShape(Capsule())
                            }
                            .accessibilityLabel("媒体库分类：\(selection.title)")
                            .accessibilityIdentifier("library.categories")
                        }
                    }

                    if showsTopActions {
                        ToolbarItem(placement: .principal) {
                            BrowseSegmentedControl(destinations: quickDestinations,
                                                   selection: selection,
                                                   identifierPrefix: "library.quick",
                                                   onSelect: select)
                        }
                    }
                }
        }
        .onAppear { if selection == .home { selection = destination } }
        .onChange(of: router.libraryHomeRequest) { _, _ in
            guard DeviceInfo.isPad else { return }
            select(.home)
        }
        .environmentObject(nav)   // 挂在栈外面，push 出来的页面也能拿到
    }
}

/// 偏好：默认展示全部影视，顶栏是类型 / 年代 / 评分 / 分级 / 收藏夹
struct PreferencesTab: View {
    @StateObject private var nav = NavModel()
    @EnvironmentObject private var router: AppSectionRouter
    @State private var selection: BrowseDestination = .genres

    private let quickDestinations: [BrowseDestination] = [
        .genres, .years, .ratings, .certifications, .favorites
    ]
    private var showsTopActions: Bool { DeviceInfo.isPad && nav.path.isEmpty }

    private func select(_ destination: BrowseDestination) {
        nav.path = NavigationPath()
        selection = destination
    }

    private var topSearch: (() -> Void)? {
        guard nav.path.isEmpty else { return nil }
        return { nav.open(BrowseRoute.list(.search)) }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .genres:
            LibraryCategoryView(kind: .genres, onSearch: topSearch, searchIdentifier: "preferences.search")
        case .years:
            LibraryCategoryView(kind: .years, onSearch: topSearch, searchIdentifier: "preferences.search")
        case .ratings:
            LibraryCategoryView(kind: .ratings, onSearch: topSearch, searchIdentifier: "preferences.search")
        case .certifications:
            LibraryCategoryView(kind: .certifications, onSearch: topSearch, searchIdentifier: "preferences.search")
        default:
            BrowseView(destination: selection, onOpenDestination: select,
                       onSearch: topSearch, searchIdentifier: "preferences.search")
        }
    }

    var body: some View {
        NavigationStack(path: $nav.path) {
            content
                .detailDestinations()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SectionMenu()
                    }
                    if showsTopActions {
                        ToolbarItem(placement: .principal) {
                            BrowseSegmentedControl(destinations: quickDestinations,
                                                   selection: selection,
                                                   identifierPrefix: "preferences.quick",
                                                   onSelect: select)
                        }
                    }
                }
        }
        .environmentObject(nav)
    }
}
#endif

// MARK: - 导航目标（只注册一次，避免多层 NavigationStack 重复注册导致 push 变成替换）

extension View {
    func detailDestinations() -> some View {
        navigationDestination(for: BrowseRoute.self) { route in
            switch route {
            case .list(let destination):
                switch destination {
                case .years: LibraryCategoryView(kind: .years)
                case .genres: LibraryCategoryView(kind: .genres)
                case .ratings: LibraryCategoryView(kind: .ratings)
                case .certifications: LibraryCategoryView(kind: .certifications)
                case .search: LibrarySearchView()
                default: BrowseView(destination: destination)
                }
            case .category(let category):
                BrowseView(destination: .allMedia, category: category)
            }
        }
        .navigationDestination(for: DetailTarget.self) { target in
            switch target {
            case .series(let group): MediaDetailView(series: group)
            case .movie(let item):   MediaDetailView(movie: item)
            }
        }
        .navigationDestination(for: PersonRoute.self) { route in
            PersonView(route: route)
        }
    }
}
