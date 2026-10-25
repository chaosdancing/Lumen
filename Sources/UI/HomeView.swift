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
        case .movie(let item): return metadata.libraryMetadata(for: item)
        case .series(let group): return metadata.libraryMetadata(for: group)
        }
    }

    @MainActor
    func displayTitle(in metadata: MetadataStore) -> String {
        let value = self.metadata(in: metadata)?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : title
    }

    @MainActor
    func displaySubtitle(in store: AppStore, metadata: MetadataStore) -> String? {
        let year = queryItem(in: store, metadata: metadata).year.map(String.init)
        switch self {
        case .movie: return year ?? subtitle
        case .series(let group): return [year, group.seasonSummary].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @MainActor
    func queryItem(in store: AppStore, metadata: MetadataStore) -> LibraryQuery.Item {
        let meta = self.metadata(in: metadata)
        let items: [MediaItem]
        switch self {
        case .movie(let item): items = [item]
        case .series(let group): items = group.items
        }
        let records = items.compactMap { store.record(for: $0.id) }
        let active = records.filter { !$0.isFinished && $0.progress > 0.02 }
        let premiereYear = meta?.releaseDate.flatMap { Int($0.prefix(4)) }
        // Episode air dates and filename years are not a series premiere.
        let year: Int?
        switch self {
        case .movie(let item): year = premiereYear ?? item.year
        case .series: year = premiereYear
        }
        let displayName = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryQuery.Item(
            id: id, title: displayName?.isEmpty == false ? displayName! : title,
            searchTerms: [title] + [meta?.originalTitle, meta?.seriesTitle].compactMap { $0 }
                + items.compactMap(\.seriesTitle) + (meta?.cast.map(\.name) ?? []),
            year: year, genres: meta?.genres ?? [], rating: meta?.rating,
            certification: meta?.certification, certificationRegion: meta?.certificationRegion,
            isSeries: items.first?.seriesTitle != nil,
            addedAt: sortDate,
            isWatched: !items.isEmpty && records.count == items.count && records.allSatisfy(\.isFinished),
            isContinuing: !active.isEmpty,
            lastPlayedAt: active.map(\.updatedAt).max())
    }
}

@MainActor
struct LibrarySnapshot {
    let entries: [BrowseEntry]
    let items: [LibraryQuery.Item]

    private struct CacheKey: Equatable {
        let content: UInt64
        let metadata: UInt64
        let preferNFO: Bool
        let language: String
    }
    private struct Cached {
        weak var store: AppStore?
        weak var metadata: MetadataStore?
        let key: CacheKey
        let entries: [BrowseEntry]
        let items: [LibraryQuery.Item]
    }
    private static var cache: Cached?

    init(store: AppStore, metadata: MetadataStore) {
        let key = CacheKey(content: store.contentRevision, metadata: metadata.revision,
                           preferNFO: Preferences.shared.preferNFO, language: TMDBClient.language)
        if let cached = Self.cache, cached.store === store, cached.metadata === metadata,
           cached.key == key {
            entries = cached.entries
            items = cached.items
            return
        }
        entries = store.seriesGroups.map(BrowseEntry.series) + store.movieItems.map(BrowseEntry.movie)
        items = entries.map { $0.queryItem(in: store, metadata: metadata) }
        Self.cache = Cached(store: store, metadata: metadata, key: key, entries: entries, items: items)
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

struct BrowseView: View {
    let destination: BrowseDestination
    var searchText = ""
    var category: LibraryQuery.Category? = nil
    /// 点「全部」时切到对应模块（由 RootView 传进来，因为切换的是侧边栏选中项）
    var onOpenDestination: ((BrowseDestination) -> Void)? = nil

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

    typealias SortOption = LibraryQuery.Sort

    private let grid = [GridItem(.adaptive(minimum: 112, maximum: 146), spacing: 14)]

    /// 轮播高度：跟窗口走，比详情页头图略矮一点，给下方分区留位置
    @State private var viewport: CGSize = CGSize(width: 1100, height: 700)

    private var heroHeight: CGFloat {
        #if os(macOS)
        return min(max(viewport.height * 0.68, 380), 760)
        #else
        return min(max(viewport.height * 0.46, 280), 520)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            if destination == .home {
                homeSections
            } else if entries.isEmpty {
                EmptyStateView(symbol: destination.symbol,
                               title: "没有内容",
                               message: emptyMessage,
                               actionTitle: nil, action: nil)
            } else if listMode {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        TileTap(target: entry.target) {
                            BrowseListRow(entry: entry)
                        }
                        Divider().opacity(0.25).padding(.leading, 64)
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
                            PosterTile(title: entry.displayTitle(in: metaStore),
                                       subtitle: entry.displaySubtitle(in: store, metadata: metaStore),
                                       item: entry.posterItem,
                                       badge: ratingBadge(for: entry) ?? entry.badge,
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
                                Button(store.isSeriesFavorite(s) ? "取消收藏" : "收藏") {
                                    store.toggleSeriesFavorite(s)
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
        .background {
            if destination == .home || destination == .recentlyAdded {
                // heroItem 由轮播回调设置，首帧可能还是 nil → 退回第一条，别让背景空着
                BlurredBackdrop(item: heroItem ?? entries.first?.posterItem, scheme: colorScheme)
            }
        }
        .measureViewport { viewport = $0 }
        #if os(iOS)
        .navigationTitle(destination == .home ? "" : (category?.title ?? destination.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .tabBar)
        #else
        .navigationTitle(category?.title ?? destination.title)
        #endif
        .onAppear {
            if destination == .search {
                sort = .rating
            } else if destination == .recentlyAdded {
                sort = .added
            } else {
                switch prefs.defaultSort {
                case "title": sort = .title
                case "year":  sort = .year
                case "rating": sort = .rating
                default:      sort = .added
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if destination == .home {
                    #if os(macOS)
                    Button {
                        NotificationCenter.default.post(name: .lumenFind, object: nil)
                    } label: {
                        Label("查找", systemImage: "magnifyingglass")
                    }
                    .help("查找媒体库（⌘F）")
                    #else
                    NavigationLink(value: BrowseRoute.list(.search)) {
                        Label("查找", systemImage: "magnifyingglass")
                    }
                    #endif
                } else {
                    LibraryToolbar(sort: $sort, state: $filter, listMode: $listMode,
                                   compact: viewport.width < 540)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: filter)
        .animation(.smooth(duration: 0.25), value: sort)
    }

    // MARK: 媒体库首页（大图轮播 + 三行分区）

    @ViewBuilder private var homeSections: some View {
        let series = store.seriesGroups
        let movies = store.movieItems
        let activeIDs = Set(store.progress.filter { !$0.value.isFinished && $0.value.progress > 0.02 }.keys)
        let continueItems = (series.filter { g in g.items.contains { activeIDs.contains($0.id) } }.map { BrowseEntry.series($0) }
                             + movies.filter { activeIDs.contains($0.id) }.map { BrowseEntry.movie($0) })

        VStack(alignment: .leading, spacing: 26) {
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
            }

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
        .padding(.bottom, 24)
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
                            PosterTile(title: entry.displayTitle(in: metaStore),
                                       subtitle: entry.displaySubtitle(in: store, metadata: metaStore),
                                       item: entry.posterItem,
                                       badge: ratingBadge(for: entry) ?? entry.badge,
                                       progress: progress(for: entry),
                                       width: 118)
                        }
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }


    private var allLabel: some View {
        HStack(spacing: 2) {
            Text("全部").font(.system(size: 12))
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .contentShape(Rectangle())
    }

    private var emptyMessage: String {
        switch destination {
        case .search: return searchText.isEmpty ? "暂无未看推荐，可输入片名搜索所有内容。" : "没有匹配的名称、原名或已缓存演员。"
        case .home:             return "到「文件源」里添加 NAS、WebDAV 或本地文件夹，扫描后影片会出现在这里。"
        case .continueWatching: return "还没有播放记录。播放过的影片会出现在这里。"
        case .favorites:        return "还没有收藏。在影片上右键可以收藏。"
        case .source:           return "这个源里还没扫到视频。到「文件源」页面点扫描。"
        default:                return "扫描后内容会出现在这里。"
        }
    }

    // MARK: 数据

    private var entries: [BrowseEntry] {
        let snapshot = LibrarySnapshot(store: store, metadata: metaStore)
        let allowed = snapshot.entries.filter { entry in
            let item = entry.queryItem(in: store, metadata: metaStore)
            switch destination {
            case .movies: if case .movie = entry { return true }; return false
            case .series: if case .series = entry { return true }; return false
            case .continueWatching: return item.isContinuing
            case .unwatched: return !item.isWatched
            case .watched: return item.isWatched
            case .favorites:
                switch entry {
                case .movie(let movie): return store.isFavorite(movie.id)
                case .series(let series): return store.isSeriesFavorite(series)
                }
            case .source(let id): return entry.posterItem?.sourceID == id
            case .sourceGroup, .years, .genres, .ratings, .certifications: return false
            default: return true
            }
        }
        let ids = Set(allowed.map(\.id))
        let candidates = snapshot.items.filter { ids.contains($0.id) }
        if destination == .search && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if filter == .watched {
                return snapshot.entries(for: LibraryQuery.results(candidates, state: .watched, sort: sort))
            }
            let recommendations = LibraryQuery.recommendations(
                LibraryQuery.results(candidates, state: filter))
            return snapshot.entries(for: sort == .rating ? recommendations
                                    : LibraryQuery.results(recommendations, sort: sort))
        }
        return snapshot.entries(for: LibraryQuery.results(candidates, search: searchText, state: filter,
                                                          sort: sort, category: category,
                                                          recent: destination == .recentlyAdded))
    }

    private func ratingBadge(for entry: BrowseEntry) -> String? {
        guard prefs.showRatings else { return nil }
        guard let rating = entry.metadata(in: metaStore)?.rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
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

private struct BrowseListRow: View {
    let entry: BrowseEntry
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metadata = MetadataStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: entry.posterItem, cornerRadius: 4)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle(in: metadata)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let sub = entry.displaySubtitle(in: store, metadata: metadata) {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let badge = entry.badge {
                Text(badge).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
