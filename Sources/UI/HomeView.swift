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
    /// 点「全部」时切到对应模块（由 RootView 传进来，因为切换的是侧边栏选中项）
    var onOpenDestination: ((BrowseDestination) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerPresenter
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
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
        case added, title, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .added: return "添加时间"
            case .title: return "名称"
            case .year:  return "年份"
            }
        }
    }

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
                            PosterTile(title: entry.title,
                                       subtitle: entry.subtitle,
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .tabBar)
        #else
        .navigationTitle(destination.title)
        #endif
        .onAppear {
            switch prefs.defaultSort {
            case "title": sort = .title
            case "year":  sort = .year
            default:      sort = .added
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if destination != .home {
                Menu {
                    ForEach(SortOption.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            Label(option.label, systemImage: sort == option ? "checkmark" : "arrow.up.arrow.down")
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }

                Picker("", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 168)

                Button {
                    withAnimation(.smooth(duration: 0.2)) { listMode.toggle() }
                } label: {
                    Label("布局", systemImage: listMode ? "square.grid.2x2" : "list.bullet")
                }
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
                            PosterTile(title: entry.title,
                                       subtitle: entry.subtitle,
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
        case .home:             return "到「文件源」里添加 NAS、WebDAV 或本地文件夹，扫描后影片会出现在这里。"
        case .continueWatching: return "还没有播放记录。播放过的影片会出现在这里。"
        case .favorites:        return "还没有收藏。在影片上右键可以收藏。"
        case .source:           return "这个源里还没扫到视频。到「文件源」页面点扫描。"
        default:                return "扫描后内容会出现在这里。"
        }
    }

    // MARK: 数据

    private var entries: [BrowseEntry] {
        let movies = store.movieItems
        let series = store.seriesGroups
        var result: [BrowseEntry] = []

        func movieEntries(_ list: [MediaItem]) -> [BrowseEntry] { list.map { .movie($0) } }
        func seriesEntries(_ list: [SeriesGroup]) -> [BrowseEntry] { list.map { .series($0) } }

        switch destination {
        case .movies:
            result = movieEntries(movies)
        case .series:
            result = seriesEntries(series)
        case .continueWatching:
            let activeIDs = Set(store.progress.filter { !$0.value.isFinished && $0.value.progress > 0.02 }.keys)
            let activeMovies = movies.filter { activeIDs.contains($0.id) }
            let activeSeries = series.filter { group in
                group.items.contains { activeIDs.contains($0.id) }
            }
            result = seriesEntries(activeSeries) + movieEntries(activeMovies)
        case .home, .recentlyAdded:
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
        case .sourceGroup:
            result = []
        }

        if !query.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if filter == .unwatched {
            result = result.filter { entry in
                switch entry {
                case .movie(let m):  return store.record(for: m.id) == nil
                case .series(let s): return s.items.contains { store.record(for: $0.id) == nil }
                }
            }
        }

        switch sort {
        case .added: result.sort { $0.sortDate > $1.sortDate }
        case .title: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year:
            result.sort { ($0.posterItem?.year ?? 0) > ($1.posterItem?.year ?? 0) }
        }
        return result
    }

    private func ratingBadge(for entry: BrowseEntry) -> String? {
        guard prefs.showRatings else { return nil }
        guard let id = entry.posterItem?.id,
              let rating = metaStore.metadata(for: id)?.rating, rating > 0 else { return nil }
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: entry.posterItem, cornerRadius: 4)
                .frame(width: 40, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let sub = entry.subtitle {
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
