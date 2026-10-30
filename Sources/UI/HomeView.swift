import SwiftUI

// MARK: - 详情目标

enum DetailTarget: Hashable {
    case series(SeriesGroup)
    case movie(MediaItem)
}

// MARK: - 浏览条目

enum BrowseEntry: Identifiable {
    case movie(MediaItem)
    case series(SeriesGroup)

    var id: String {
        switch self {
        case .movie(let m):  return "m:\(m.id)"
        case .series(let s): return "s:\(s.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let m):  return m.title
        case .series(let s): return s.title
        }
    }

    var subtitle: String? {
        switch self {
        case .movie(let m):
            if let y = m.year { return String(y) }
            return m.addedAt.formatted(date: .numeric, time: .omitted)
        case .series(let s):
            return s.seasonSummary
        }
    }

    var posterItem: MediaItem? {
        switch self {
        case .movie(let m):  return m
        case .series(let s): return s.posterItem
        }
    }

    var badge: String? {
        switch self {
        case .movie:         return nil
        case .series(let s): return "\(s.episodeCount) 集"
        }
    }

    var target: DetailTarget {
        switch self {
        case .movie(let m):  return .movie(m)
        case .series(let s): return .series(s)
        }
    }

    var sortDate: Date {
        switch self {
        case .movie(let m):  return m.addedAt
        case .series(let s): return s.items.map(\.addedAt).max() ?? .distantPast
        }
    }
}

/// 「全部」列表页的路由
enum BrowseRoute: Hashable {
    case list(BrowseDestination)
    case category(LibraryQuery.Category)
}

extension BrowseEntry {
    @MainActor
    func metadata(in metadata: MetadataStore) -> MediaMetadata? {
        switch self {
        case .movie(let item):
            return metadata.metadata(for: item.id)
        case .series(let group):
            if let poster = group.posterItem, let value = metadata.metadata(for: poster.id) {
                return value
            }
            return group.items.lazy.compactMap { metadata.metadata(for: $0.id) }.first
        }
    }

    @MainActor
    func queryItem(in store: AppStore, metadata: MetadataStore) -> LibraryQuery.Item {
        let meta = self.metadata(in: metadata)
        let mediaItems: [MediaItem]
        switch self {
        case .movie(let item): mediaItems = [item]
        case .series(let group): mediaItems = group.items
        }
        let premiereYear = meta?.releaseDate.flatMap { Int($0.prefix(4)) }
        let year: Int?
        switch self {
        case .movie(let item): year = premiereYear ?? item.year
        case .series: year = premiereYear
        }
        let displayName = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = mediaItems.compactMap { store.record(for: $0.id) }
        return LibraryQuery.Item(
            id: id,
            title: displayName?.isEmpty == false ? displayName! : title,
            searchTerms: [meta?.originalTitle, meta?.seriesTitle, title]
                .compactMap { $0 } + (meta?.cast.map(\.name) ?? []),
            year: year,
            genres: meta?.genres ?? [],
            rating: meta?.rating,
            certification: meta?.certification,
            certificationRegion: meta?.certificationRegion,
            isSeries: mediaItems.first?.seriesTitle != nil,
            addedAt: sortDate,
            isWatched: !mediaItems.isEmpty && mediaItems.allSatisfy { store.record(for: $0.id)?.isFinished == true },
            isContinuing: records.contains(where: \.isInProgress),
            lastPlayedAt: records.map(\.updatedAt).max()
        )
    }
}

@MainActor
struct LibrarySnapshot {
    let entries: [BrowseEntry]
    let items: [LibraryQuery.Item]

    init(store: AppStore, metadata: MetadataStore) {
        entries = store.seriesGroups.map(BrowseEntry.series) + store.movieItems.map(BrowseEntry.movie)
        items = entries.map { $0.queryItem(in: store, metadata: metadata) }
    }

    func entries(for results: [LibraryQuery.Item]) -> [BrowseEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return results.compactMap { byID[$0.id] }
    }
}

/// 导航状态：用 ObservableObject 而不是 EnvironmentValues 闭包，
/// 因为 environmentObject 能可靠地传到 push 出来的页面里。
@MainActor
final class NavModel: ObservableObject {
    @Published var path = NavigationPath()
    func open(_ target: DetailTarget) { path.append(target) }
    func open(_ route: BrowseRoute) { path.append(route) }
}

/// 卡片点击：iOS 走显式路径，macOS 走 NavigationLink
struct TileTap<Label: View>: View {
    let target: DetailTarget
    @ViewBuilder var label: () -> Label
    #if os(iOS)
    @EnvironmentObject private var nav: NavModel
    #endif

    var body: some View {
        #if os(iOS)
        Button { nav.open(target) } label: { label() }
            .buttonStyle(.plain)
        #else
        NavigationLink(value: target) { label() }
            .buttonStyle(.plain)
        #endif
    }
}

// MARK: - 浏览页

struct BrowseControlLabel: View {
    let title: String
    let symbol: String
    var selected = false

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                 : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5)
                                                     : Color.primary.opacity(0.12)))
            .contentShape(Capsule())
    }
}

struct BrowseView: View {
    let destination: BrowseDestination
    var searchText = ""
    var category: LibraryQuery.Category? = nil
    /// 点「全部」时切到对应模块（由 RootView 传进来，因为切换的是侧边栏选中项）
    var onOpenDestination: ((BrowseDestination) -> Void)? = nil
    /// iPad 顶栏搜索入口：nil 时不显示（iPhone 用页面内搜索框）
    var onSearch: (() -> Void)? = nil
    var searchIdentifier = "library.search"

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerPresenter
    @Environment(\.colorScheme) private var colorScheme

    @State private var filter: LibraryFilter = .all
    @State private var sort: SortOption = .added
    @ObservedObject private var prefs = Preferences.shared
    @State private var listMode = false
    @ObservedObject private var metaStore = MetadataStore.shared
    #if os(iOS)
    @EnvironmentObject private var nav: NavModel
    #endif
    /// 轮播当前那一条的封面：用来铺整页的虚化背景
    @State private var heroItem: MediaItem?

    enum SortOption: String, CaseIterable, Identifiable {
        case added, title, year, rating, certification
        var id: String { rawValue }
        var label: String {
            switch self {
            case .added: return "添加时间"
            case .title: return "名称"
            case .year:  return "年份"
            case .rating: return "评分"
            case .certification: return "分级"
            }
        }
    }

    #if os(iOS)
    private let grid = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]
    private let rowPosterWidth: CGFloat = 154
    #else
    private let grid = [GridItem(.adaptive(minimum: 112, maximum: 146), spacing: 14)]
    private let rowPosterWidth: CGFloat = 118
    #endif

    /// 轮播高度：跟窗口走，比详情页头图略矮一点，给下方分区留位置
    @State private var viewport: CGSize = CGSize(width: 1100, height: 700)

    private var heroHeight: CGFloat {
        #if os(macOS)
        return min(max(viewport.height * 0.68, 380), 760)
        #elseif os(iOS)
        if DeviceInfo.isPad {
            // iPad 头图更高，下缘在影片区背后继续淡出
            return min(max(viewport.height * 0.56, 440), 680)
        }
        return min(max(viewport.height * 0.46, 280), 520)
        #else
        return min(max(viewport.height * 0.68, 380), 760)
        #endif
    }

    var body: some View {
        // entries 涉及全库分组 / 过滤 / 排序，body 里被引用 6+ 次；只算一次再传下去。
        content(entries: entries)
    }

    private func content(entries: [BrowseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            if destination == .home {
                homeSections(entries: entries)
            } else if entries.isEmpty {
                EmptyStateView(symbol: destination.symbol,
                               title: "没有内容",
                               message: emptyMessage,
                               actionTitle: nil, action: nil)
            } else if listMode {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        TileTap(target: entry.target) {
                            BrowseListRow(entry: entry, badge: displayBadge(for: entry))
                        }
                        Divider().opacity(0.25).padding(.leading, 108)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            } else {
                if destination == .recentlyAdded, prefs.showCarousel, entries.count > 1 {
                    HeroCarousel(entries: Array(entries.prefix(8)),
                                 height: heroHeight,
                                 currentItem: $heroItem)
                        .padding(.bottom, 6)
                }
                LazyVGrid(columns: grid, alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        TileTap(target: entry.target) {
                            PosterTile(title: entry.title,
                                       subtitle: entry.subtitle,
                                       item: entry.posterItem,
                                       badge: displayBadge(for: entry),
                                       progress: progress(for: entry))
                        }
                        .contextMenu {
                            switch entry {
                            case .movie(let m):
                                Button("播放") { player.play(m) }
                                Button(store.isFavorite(m.id) ? "取消收藏" : "收藏") {
                                    store.toggleFavorite(m.id)
                                }
                                Button("清除进度", role: .destructive) {
                                    store.clearProgress(itemID: m.id)
                                }
                            case .series(let s):
                                if let next = s.nextEpisode(progress: store.progress) {
                                    Button("继续观看 \(next.title)") { player.play(next) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        }
        .background(HomeBrowseBackdrop(shows: destination == .home || destination == .recentlyAdded,
                                       item: heroItem ?? entries.first?.posterItem,
                                       scheme: colorScheme))
        .measureViewport { viewport = $0 }
        #if os(iOS)
        .ignoresSafeArea(.container, edges: destination == .home && prefs.showCarousel && !entries.isEmpty ? .top : [])
        .navigationTitle(category?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .tabBar)
        #else
        .navigationTitle(category?.title ?? destination.title)
        #endif
        .onAppear {
            if let category {
                switch category {
                case .decade: sort = .year
                case .genre: sort = .title
                case .rating: sort = .rating
                case .certification: sort = .certification
                }
                return
            }
            if destination == .genres {
                sort = .title
                return
            }
            if destination == .years {
                sort = .year
                return
            }
            if destination == .ratings {
                sort = .rating
                return
            }
            if destination == .certifications {
                sort = .certification
                return
            }
            switch prefs.defaultSort {
            case "title": sort = .title
            case "year":  sort = .year
            default:      sort = .added
            }
        }
        .task(id: destination) {
            if [.genres, .years, .ratings, .certifications].contains(destination) {
                await metaStore.scrapeAll(items: store.library, in: store)
            }
        }
        .toolbar {
            #if os(macOS)
            if destination == .home {
                ToolbarItem(placement: .primaryAction) {
                    Button { onOpenDestination?(.search) } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .help("搜索媒体库")
                }
            }
            if destination != .home && destination != .search {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) { sortControls }
                        .buttonStyle(.plain)
                }
            }
            #else
            // iPad 把排序/筛选/网格和搜索放进同一个 trailing HStack，
            // 搜索固定在最后，保证始终在最右上角。
            if onSearch != nil || (destination != .home && destination != .search) {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        if let onSearch {
                            SearchToolbarButton(action: onSearch, identifier: searchIdentifier)
                        }
                        if destination != .home && destination != .search {
                            if DeviceInfo.isPad {
                                optionsMenu
                            } else {
                                sortControls
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        }
        .animation(.smooth(duration: 0.25), value: filter)
        .animation(.smooth(duration: 0.25), value: sort)
    }

    @ViewBuilder private var sortControls: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    sort = option
                } label: {
                    Label(option.label, systemImage: sort == option ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        } label: {
            BrowseControlLabel(title: sort.label, symbol: "arrow.up.arrow.down")
        }
        .help("排序：\(sort.label)")

        Menu {
            ForEach(LibraryFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Label(option.title, systemImage: filter == option ? "checkmark" : "line.3.horizontal.decrease")
                }
            }
        } label: {
            BrowseControlLabel(title: filter.title, symbol: "line.3.horizontal.decrease")
        }
        .help("筛选：\(filter.title)")

        Button {
            withAnimation(.smooth(duration: 0.2)) { listMode.toggle() }
        } label: {
            BrowseControlLabel(title: listMode ? "列表" : "网格",
                               symbol: listMode ? "list.bullet" : "square.grid.2x2")
        }
        .help(listMode ? "切换为网格" : "切换为列表")
    }

    /// iPad 顶栏空间有限：把排序、筛选、网格/列表收进一个圆形菜单，给分类胶囊留位置。
    private var optionsMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Picker("筛选", selection: $filter) {
                ForEach(LibraryFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Divider()
            Button {
                withAnimation(.smooth(duration: 0.2)) { listMode.toggle() }
            } label: {
                Label(listMode ? "切换为网格" : "切换为列表",
                      systemImage: listMode ? "square.grid.2x2" : "list.bullet")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .tint(Color.primary)
        .accessibilityLabel("筛选与排序")
        .accessibilityIdentifier("browse.options")
    }

    // MARK: 媒体库首页（大图轮播 + 三行分区）

    @ViewBuilder private func homeSections(entries: [BrowseEntry]) -> some View {
        let series = store.seriesGroups
        let movies = store.movieItems
        let continueItems = continuingEntries(series: series, movies: movies)

        VStack(alignment: .leading, spacing: 0) {
            if store.library.isEmpty {
                EmptyStateView(symbol: "play.rectangle",
                               title: "还没有内容",
                               message: "到「文件源」里添加 NAS、WebDAV 或本地文件夹，扫描后影片会出现在这里。",
                               actionTitle: nil, action: nil)
                    .padding(.top, 40)
            }
            if prefs.showCarousel, entries.count > 1 {
                HeroCarousel(entries: Array(entries.prefix(8)),
                             height: heroHeight,
                             currentItem: $heroItem)
            } else if prefs.showCarousel, let first = entries.first {
                // 只有一条内容时没有轮播，也要有一块顶到屏幕顶端的头图
                HeroCarousel(entries: [first], height: heroHeight, currentItem: $heroItem)
            }

            // iPad 把搜索与分类快捷入口移到顶栏；iPhone / macOS 仍放在首页内容里。
            if !DeviceInfo.isPad {
                searchEntry
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                quickLinks
                    .padding(.top, 14)
            }

            VStack(alignment: .leading, spacing: 26) {
                if !continueItems.isEmpty {
                    row("继续观看", continueItems.prefix(12).map { $0 }, destination: .continueWatching)
                }
                if !series.isEmpty {
                    row("剧集", series.prefix(12).map { BrowseEntry.series($0) }, destination: .series)
                }
                if !movies.isEmpty {
                    row("电影", movies.prefix(12).map { BrowseEntry.movie($0) }, destination: .movies)
                }
            }
            .padding(.top, 24)
        }
        .padding(.bottom, 24)
        .background(alignment: .top) {
            // 头图在下方继续延展：同一张剧照虚化后铺到影片区背后，再淡出到页面底色。
            if DeviceInfo.isPad, prefs.showCarousel, let item = heroItem ?? entries.first?.posterItem {
                HomeArtworkExtension(item: item, scheme: colorScheme, heroHeight: heroHeight)
            }
        }
    }

    /// 首页搜索入口：点一下进搜索页并自动聚焦输入框（和 macOS 的 ⌘F 同一条路径）
    private var searchEntry: some View {
        Button {
            #if os(iOS)
            nav.open(BrowseRoute.list(.search))
            #else
            onOpenDestination?(.search)
            #endif
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("搜索片名、原名、演员")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
        .accessibilityHint("搜索媒体库里的片名、原名或演员")
    }

    /// 年代 / 类型 / 评分 / 分级 / 最近添加：和 macOS 侧边栏一一对应，一步直达
    private var quickLinks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                quickLink(.years)
                quickLink(.genres)
                quickLink(.ratings)
                quickLink(.certifications)
                quickLink(.recentlyAdded)
            }
            .padding(.horizontal, 22)
        }
    }

    private func quickLink(_ destination: BrowseDestination) -> some View {
        Button {
            #if os(iOS)
            nav.open(BrowseRoute.list(destination))
            #else
            onOpenDestination?(destination)
            #endif
        } label: {
            BrowseControlLabel(title: destination.title, symbol: destination.symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
    }

    private func row(_ title: String, _ list: [BrowseEntry], destination: BrowseDestination? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                if let destination {
                    if let onOpenDestination {
                        Button {
                            onOpenDestination(destination)
                        } label: {
                            allLabel
                        }
                        .buttonStyle(.plain)
                        .help("查看全部\(title)")
                    } else {
                        Button {
                            #if os(iOS)
                            nav.open(BrowseRoute.list(destination))
                            #endif
                        } label: {
                            allLabel
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(list) { entry in
                        TileTap(target: entry.target) {
                            PosterTile(title: entry.title,
                                       subtitle: entry.subtitle,
                                       item: entry.posterItem,
                                       badge: displayBadge(for: entry),
                                       progress: progress(for: entry),
                                       width: rowPosterWidth)
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }


    private var allLabel: some View {
        HStack(spacing: 3) {
            Text("全部").font(.system(size: 15, weight: .medium))
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .contentShape(Rectangle())
    }

    private var emptyMessage: String {
        switch destination {
        case .search:           return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "暂无推荐内容。" : "没有匹配的名称、原名、剧名或演员。"
        case .home:             return "到「文件源」里添加 NAS、WebDAV 或本地文件夹，扫描后影片会出现在这里。"
        case .continueWatching: return "还没有播放记录。播放过的影片会出现在这里。"
        case .favorites:        return "还没有收藏。在影片上右键可以收藏。"
        case .genres:           return "还没有类型数据。请配置 TMDB API Key 或在 NFO 中提供类型。"
        case .years:            return "还没有年代数据。请配置 TMDB API Key，或在文件名/NFO 中提供年份。"
        case .ratings:          return "还没有评分数据。请配置 TMDB API Key 或提供 NFO 元数据。"
        case .certifications:   return "还没有分级数据。请配置 TMDB API Key 或在 NFO 中提供分级。"
        case .source:           return "这个源里还没扫到视频。到「文件源」页面点扫描。"
        default:                return "扫描后内容会出现在这里。"
        }
    }

    // MARK: 数据

    private var entries: [BrowseEntry] {
        if destination == .search {
            let snapshot = LibrarySnapshot(store: store, metadata: metaStore)
            let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = needle.isEmpty
                ? LibraryQuery.recommendations(snapshot.items)
                : LibraryQuery.results(snapshot.items, search: needle)
            return snapshot.entries(for: results)
        }

        let movies = store.movieItems
        let series = store.seriesGroups
        var result: [BrowseEntry] = []

        func movieEntries(_ list: [MediaItem]) -> [BrowseEntry] { list.map { .movie($0) } }
        func seriesEntries(_ list: [SeriesGroup]) -> [BrowseEntry] { list.map { .series($0) } }

        if let category {
            let snapshot = LibrarySnapshot(store: store, metadata: metaStore)
            result = snapshot.entries(for: LibraryQuery.results(snapshot.items, category: category))
        } else {
            switch destination {
            case .movies:
                result = movieEntries(movies)
            case .series:
                result = seriesEntries(series)
            case .genres, .years, .ratings, .certifications:
                // 这四个入口由 LibraryCategoryView 先展示分类桶。
                result = []
            case .continueWatching:
                result = continuingEntries(series: series, movies: movies)
            case .home, .recentlyAdded, .allMedia:
                result = seriesEntries(series) + movieEntries(movies)
            case .unwatched:
                result = seriesEntries(series.filter { group in
                    group.items.contains { store.record(for: $0.id) == nil }
                }) + movieEntries(movies.filter { store.record(for: $0.id) == nil })
            case .watched:
                result = seriesEntries(series.filter { group in
                    group.items.allSatisfy { store.record(for: $0.id)?.isFinished == true }
                }) + movieEntries(movies.filter { store.record(for: $0.id)?.isFinished == true })
            case .favorites:
                result = seriesEntries(series.filter { group in
                    group.items.contains { store.isFavorite($0.id) }
                }) + movieEntries(movies.filter { store.isFavorite($0.id) })
            case .source(let id):
                result = seriesEntries(series.filter { group in
                    group.items.allSatisfy { $0.sourceID == id }
                }) + movieEntries(movies.filter { $0.sourceID == id })
            case .search, .sourceGroup:
                result = []
            }
        }

        if filter == .unwatched {
            result = result.filter { entry in
                switch entry {
                case .movie(let m):  return store.record(for: m.id) == nil
                case .series(let s): return s.items.contains { store.record(for: $0.id) == nil }
                }
            }
        }

        if destination == .continueWatching && sort == .added { return result }
        switch sort {
        case .added: result.sort { $0.sortDate > $1.sortDate }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year:
            result.sort { (displayYear(for: $0) ?? 0) > (displayYear(for: $1) ?? 0) }
        case .rating:
            result.sort { (metadata(for: $0)?.rating ?? 0) > (metadata(for: $1)?.rating ?? 0) }
        case .certification:
            result.sort {
                let lhs = metadata(for: $0)?.certification ?? ""
                let rhs = metadata(for: $1)?.certification ?? ""
                if lhs == rhs { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
        return result
    }

    private func continuingEntries(series: [SeriesGroup], movies: [MediaItem]) -> [BrowseEntry] {
        let records = store.progress
        let activeIDs = Set(store.continueWatching.map(\.id))
        let groups = series.filter { group in group.items.contains { activeIDs.contains($0.id) } }
        let activeMovies = movies.filter { activeIDs.contains($0.id) }
        let entries = groups.map(BrowseEntry.series) + activeMovies.map(BrowseEntry.movie)
        return entries.sorted { lhs, rhs in
            func lastPlayed(_ entry: BrowseEntry) -> Date {
                switch entry {
                case .movie(let item): return records[item.id]?.updatedAt ?? .distantPast
                case .series(let group):
                    return group.items.compactMap { item in
                        guard activeIDs.contains(item.id) else { return nil }
                        return records[item.id]?.updatedAt
                    }.max() ?? .distantPast
                }
            }
            return lastPlayed(lhs) > lastPlayed(rhs)
        }
    }

    private func ratingBadge(for entry: BrowseEntry) -> String? {
        guard prefs.showRatings else { return nil }
        guard let rating = metadata(for: entry)?.rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    private func metadata(for entry: BrowseEntry) -> MediaMetadata? {
        entry.metadata(in: metaStore)
    }

    private func displayBadge(for entry: BrowseEntry) -> String? {
        if case .genre = category,
           let genres = metadata(for: entry)?.genres, !genres.isEmpty {
            return genres.prefix(2).joined(separator: " · ")
        }
        if case .decade = category, let year = displayYear(for: entry) {
            return String(year)
        }
        if case .certification = category,
           let value = metadata(for: entry)?.certification, !value.isEmpty { return value }
        return ratingBadge(for: entry) ?? entry.badge
    }

    private func displayYear(for entry: BrowseEntry) -> Int? {
        entry.queryItem(in: store, metadata: metaStore).year
    }

    private func progress(for entry: BrowseEntry) -> Double? {
        switch entry {
        case .movie(let m):
            return store.record(for: m.id)?.progress
        case .series(let s):
            guard let next = s.nextEpisode(progress: store.progress) else { return nil }
            return store.record(for: next.id)?.progress
        }
    }
}

// MARK: - 列表行


/// 头图下方的背景延展：同一张剧照虚化后继续铺开，在影片区下方淡出。
private struct HomeArtworkExtension: View {
    let item: MediaItem
    var scheme: ColorScheme
    var heroHeight: CGFloat

    private var wash: Color { scheme == .dark ? .black : .white }
    private var washOpacity: Double { scheme == .dark ? 0.42 : 0.55 }
    private var totalHeight: CGFloat { heroHeight + 500 }

    var body: some View {
        GeometryReader { proxy in
            ArtworkView(item: item, cornerRadius: 0, variant: .backdrop)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .blur(radius: 34, opaque: false)
                .overlay(wash.opacity(washOpacity))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: max(0.0, heroHeight / totalHeight - 0.07)),
                            .init(color: .black.opacity(0.90), location: heroHeight / totalHeight + 0.10),
                            .init(color: .black.opacity(0.48), location: 0.86),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .frame(height: totalHeight)
        .allowsHitTesting(false)
    }
}

private struct HomeBrowseBackdrop: View {
    let shows: Bool
    let item: MediaItem?
    let scheme: ColorScheme

    var body: some View {
        Group {
            if shows {
                // heroItem 由轮播回调设置，首帧可能还是 nil → 退回第一条，别让背景空着
                BlurredBackdrop(item: item, scheme: scheme)
            }
        }
    }
}

private struct BrowseListRow: View {
    let entry: BrowseEntry
    let badge: String?
    @ObservedObject private var metadata = MetadataStore.shared
    @State private var hovering = false

    private var overview: String? {
        guard let text = entry.metadata(in: metadata)?.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(item: entry.posterItem, cornerRadius: 7)
                .frame(width: 76, height: 114)
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let sub = entry.subtitle {
                    Text(sub)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                if let overview {
                    Text(overview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary.opacity(0.9))
                        .lineLimit(3)
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
