import SwiftUI

/// 详情页：大幅头图（约 0.7 屏高，跟窗口自适应）+ 底部叠加标题/元信息/操作，
/// 头图下缘用 smoothstep 遮罩融进页面底色，不留接缝。
struct MediaDetailView: View {
    enum Mode {
        case series(SeriesGroup)
        case movie(MediaItem)
    }

    let mode: Mode

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerPresenter
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject private var metaStore = MetadataStore.shared
    @ObservedObject private var prefs = Preferences.shared

    @State private var selectedSeason: Int?
    @State private var revealSpoiler = false
    @State private var overviewExpanded = false
    @State private var viewport: CGSize = CGSize(width: 1100, height: 700)
    @State private var actionRunning = false
    @State private var actionMessage: String?
    @State private var actionFailed = false
    @State private var actionTask: Task<Void, Never>?

    init(series: SeriesGroup) { mode = .series(series) }
    init(movie: MediaItem) { mode = .movie(movie) }

    // MARK: 数据

    private var liveSeries: SeriesGroup? {
        guard case .series(let snapshot) = mode else { return nil }
        return DetailMetadataAction.currentSeries(snapshot, in: store) ?? snapshot
    }

    private var liveMovie: MediaItem? {
        guard case .movie(let snapshot) = mode else { return nil }
        return store.library.first { $0.id == snapshot.id } ?? snapshot
    }

    private var title: String {
        liveSeries?.title ?? liveMovie?.title ?? ""
    }

    private var posterItem: MediaItem? {
        liveSeries?.posterItem ?? liveMovie
    }

    private var playTarget: MediaItem? {
        if let s = liveSeries { return s.nextEpisode(progress: store.progress) }
        return liveMovie
    }

    private var isFavorite: Bool {
        if let series = liveSeries { return store.isSeriesFavorite(series) }
        guard let id = liveMovie?.id else { return false }
        return store.isFavorite(id)
    }

    private func toggleFavorite() {
        if let series = liveSeries {
            store.toggleSeriesFavorite(series)
        } else if let id = liveMovie?.id {
            store.toggleFavorite(id)
        }
    }

    private var meta: MediaMetadata? {
        guard let item = posterItem else { return nil }
        if liveSeries != nil { return metaStore.cachedSeriesMetadata(for: item) }
        return metaStore.metadata(for: item.id)
    }

    private var displayTitle: String {
        if let t = meta?.title, !t.isEmpty { return t }
        return title
    }

    private var overviewText: String? {
        guard let o = meta?.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !o.isEmpty else { return nil }
        return o
    }

    /// 第一行元信息：年份/上映日 · 类型
    private var metaPrimaryLine: String {
        var parts: [String] = []
        if let date = meta?.releaseDate, !date.isEmpty {
            parts.append(date.replacingOccurrences(of: "-", with: "/"))
        } else if liveSeries == nil, let y = posterItem?.year {
            parts.append(String(y))
        }
        if let genres = meta?.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: " / "))
        }
        if let minutes = meta?.runtimeMinutes, minutes > 0 { parts.append("\(minutes) 分钟") }
        if let certification = LibraryQuery.certificationLabel(meta?.certification) {
            let region = meta?.certificationRegion.map { " (\($0))" } ?? ""
            parts.append(certification + region)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// 第二行元信息：大小 · 来源
    private var metaSecondaryLine: String {
        var parts: [String] = []
        if let size = posterItem?.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let src = posterItem.flatMap({ store.source(for: $0.sourceID) }) {
            parts.append(src.name)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// 规格标签（VidHub 那颗「4K · MP4」胶囊）
    private var qualityLabel: String? {
        guard let name = posterItem?.fileName else { return nil }
        var parts: [String] = []
        let lower = name.lowercased()
        if lower.contains("2160p") || lower.contains("4k") { parts.append("4K") }
        else if lower.contains("1080p") { parts.append("1080P") }
        else if lower.contains("720p") { parts.append("720P") }
        if let ext = name.split(separator: ".").last { parts.append(String(ext).uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var playLabel: String {
        if let record = playTarget.flatMap({ store.record(for: $0.id) }),
           record.progress > 0.02, !record.isFinished {
            return "继续观看"
        }
        return "播放"
    }

    private var pageBackground: Color { Color.pageBackground }

    /// 头图高度：跟窗口走（VidHub 的比例约 0.68 屏高），并设上下限
    private func heroHeight(_ size: CGSize) -> CGFloat {
        #if os(macOS)
        return min(max(size.height * 0.80, 460), 860)
        #else
        let h = min(size.height * 0.66, size.width * 1.02)
        return min(max(h, 360), 760)
        #endif
    }

    private var hPad: CGFloat {
        #if os(macOS)
        return 40
        #else
        return 20
        #endif
    }

    // MARK: 主体

    @ViewBuilder
    private var detailScrollView: some View {
        #if os(macOS)
        MainScrollView { detailScrollContent }
        #else
        ScrollView { detailScrollContent }
        #endif
    }

    @ViewBuilder
    private var detailScrollContent: some View {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    sections
                        .padding(.horizontal, hPad)
                        .padding(.top, 26)
                        .padding(.bottom, 48)
                }
            
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 整页背景 = 同一张剧照的虚化版，头图淡出后直接接上，正文就浮在上面
            pageBackground.ignoresSafeArea()
            BlurredBackdrop(item: posterItem, scheme: colorScheme)

            detailScrollView
                .ignoresSafeArea(edges: .top)
                .measureViewport { viewport = $0 }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("更新元数据", systemImage: "arrow.triangle.2.circlepath") {
                        performAction(rescan: false)
                    }
                    Button(liveSeries == nil ? "重新扫描当前文件" : "重新扫描当前剧集",
                           systemImage: "arrow.clockwise") {
                        performAction(rescan: true)
                    }
                } label: {
                    Label("更多操作", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .disabled(actionRunning || posterItem == nil)
                .help("更新元数据或重新扫描当前内容")
            }
        }
        .onAppear { AppLog.info("详情页打开：\(title)") }
        .onDisappear { actionTask?.cancel() }
        .task(id: posterItem?.id) {
            if let item = posterItem {
                if liveSeries != nil {
                    _ = await metaStore.seriesMetadata(for: item, in: store)
                } else {
                    await metaStore.load(for: item, in: store)
                }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let height = heroHeight(viewport)
        // 底部留出一段"只渐变、不压字"的区域：文字全部落在渐变开始之前，
        // 深色/浅色主题下都不会出现白字压白底
        let bottomInset = max(48, height * 0.105)

        return ZStack(alignment: .bottomLeading) {
            backdrop

            info(wide: viewport.width >= 900)
                .padding(.horizontal, hPad)
                .padding(.bottom, bottomInset)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: height)
    }

    /// 头图本体：横版剧照 + 三层压暗（顶部/左侧/底部）
    /// 剧照用 smoothstep 遮罩收尾，直接"化"进页面底色；压暗层自己一路收到 0，底边不留硬切
    private var backdrop: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 浅色主题下画面容易发灰，压暗层加码，保证白字始终压得住
            let scrim: Double = colorScheme == .dark ? 1.0 : 1.5

            ZStack {
                ArtworkView(item: posterItem, cornerRadius: 0, variant: .backdrop)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask(HeroFade.gradient(start: 0.74))

                HeroScrims(strength: scrim)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    // MARK: 头图上的信息块

    @ViewBuilder
    private func info(wide: Bool) -> some View {
        if wide, let overview = overviewText {
            HStack(alignment: .bottom, spacing: 44) {
                leftColumn
                    .frame(maxWidth: 430, alignment: .leading)
                synopsis(overview)
                    .frame(maxWidth: 660, alignment: .leading)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                leftColumn
                if let overview = overviewText {
                    synopsis(overview)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(displayTitle)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .shadow(color: .black.opacity(0.45), radius: 16, y: 3)

            HStack(spacing: 8) {
                if let rating = meta?.rating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.25))
                }
                if !metaPrimaryLine.isEmpty {
                    Text(metaPrimaryLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 10)

            if let s = liveSeries {
                HStack(spacing: 6) {
                    badge("\(s.seasons.count) 季")
                    badge("\(s.episodeCount) 集")
                }
            }

            HStack(spacing: 10) {
                Button {
                    if let target = playTarget { player.play(target) }
                } label: {
                    Label(playLabel, systemImage: "play.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(width: 148, height: 38)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        // 命中区跟着胶囊走：否则只有文字/图标那一小块能点
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playTarget == nil)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)

                circleButton(isFavorite ? "heart.fill" : "heart") {
                    toggleFavorite()
                }
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
            }
            .padding(.top, 2)

            if let record = playTarget.flatMap({ store.record(for: $0.id) }), record.progress > 0.02 {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(.white.opacity(0.24))
                        .frame(width: 200, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 200 * record.progress, height: 3)
                        }
                    Text("已看 \(Int(record.progress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            HStack(spacing: 8) {
                if let qualityLabel {
                    Text(qualityLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.92))
                }
                if !metaSecondaryLine.isEmpty {
                    Text(metaSecondaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func synopsis(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if prefs.hideSpoilers && !revealSpoiler {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { revealSpoiler = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash").font(.system(size: 10))
                        Text("简介已隐藏，点击显示").font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(4)
                    .lineLimit(overviewExpanded ? nil : 7)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.35), radius: 8)

                if text.count > 170 {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { overviewExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(overviewExpanded ? "收起" : "展开全部")
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: overviewExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 下方功能区

    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: 28) {
            metadataStatus
            if overviewText == nil && meta == nil && TMDBClient.apiKey == nil {
                noMetadataHint
            }

            if let s = liveSeries, !s.items.isEmpty {
                episodeSection(s)
            }

            if let cast = meta?.cast, !cast.isEmpty {
                castSection(cast)
            }

            fileSection
        }
    }

    @ViewBuilder private var metadataStatus: some View {
        if actionRunning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(actionMessage ?? "正在处理…").font(.caption)
            }
        } else if let actionMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: actionFailed ? "exclamationmark.triangle" : "checkmark.circle")
                Text(actionMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                if actionFailed {
                    Button("重试") { performAction(rescan: retryRescan) }
                        .controlSize(.small)
                }
            }
            .foregroundStyle(actionFailed ? Color.orange : Color.secondary)
        } else if let item = posterItem, metaStore.inFlight.contains(item.id) {
            HStack {
                ProgressView().controlSize(.small)
                Text("正在读取影视信息…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let item = posterItem, let state = metaStore.loadState[item.id] {
            metadataLoadStatus(state)
        }
    }

    @State private var retryRescan = false

    @ViewBuilder private func metadataLoadStatus(_ state: MetadataLoadState) -> some View {
        if state.isLoading {
            HStack {
                ProgressView().controlSize(.small)
                Text(state.text ?? "正在读取影视信息…").font(.caption)
            }
        } else if let message = state.error {
            HStack(alignment: .top) {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("重试") { performAction(rescan: false) }.controlSize(.small)
            }
        } else if meta == nil, let text = state.text {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func performAction(rescan: Bool) {
        guard !actionRunning, let item = posterItem else { return }
        retryRescan = rescan
        actionRunning = true
        actionFailed = false
        actionMessage = rescan ? "正在重新扫描当前内容…" : "正在更新元数据，本地 NFO 字段优先…"
        let series = liveSeries
        actionTask = Task { @MainActor in
            defer { actionRunning = false }
            do {
                if rescan {
                    _ = try await DetailMetadataAction.rescanAndLoad(item: item, series: series, in: store)
                } else {
                    await metaStore.refresh(for: item, in: store)
                    if series != nil { _ = await metaStore.seriesMetadata(for: item, in: store) }
                    if let message = metaStore.loadState[item.id]?.error {
                        throw SourceError.invalidResponse(message)
                    }
                }
                guard !Task.isCancelled else { return }
                actionMessage = rescan ? "重新扫描完成"
                    : (meta == nil ? "没有找到可用元数据，请检查本地 NFO 或 TMDB 设置。" : "元数据更新完成")
            } catch {
                guard !Task.isCancelled else { return }
                actionFailed = true
                actionMessage = error.localizedDescription
            }
        }
    }

    private var noMetadataHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("还没有刮削信息")
                .font(.system(size: 12.5, weight: .medium))
            Text("设置 → 资源 里填 TMDB API Key，或在片源目录放 .nfo，就能显示简介、评分和演职员。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(.white.opacity(0.16), in: Capsule())
            .foregroundStyle(.white.opacity(0.92))
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.16), in: Circle())
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 选集

    private func episodeSection(_ group: SeriesGroup) -> some View {
        let season = selectedSeason ?? group.seasons.first ?? 1
        let episodes = group.items(in: season)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SeasonPosterView(seriesItem: group.posterItem, season: season, width: 46)
                seasonPicker(group, current: season)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(episodes) { item in
                        Button { player.play(item) } label: {
                            EpisodeThumb(item: item,
                                         record: store.record(for: item.id),
                                         title: episodeTitle(for: item, in: group),
                                         width: 156)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .task(id: season) {
                // 逐集读本地 nfo，拿"集标题"（不是文件名）
                for ep in episodes.prefix(40) {
                    await metaStore.load(for: ep, in: store)
                }
            }
        }
        .padding(12)
        .background {
            #if os(macOS)
            // macOS 上选集区直接浮在模糊背景上，不要再加一层明显的灰色卡片底。
            Color.clear
            #else
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            #endif
        }
    }

    /// 季选择：横排胶囊可点，季数多时两侧出箭头
    private func seasonPicker(_ group: SeriesGroup, current: Int) -> some View {
        ScrollViewReader { proxy in
            HStack(spacing: 6) {
                if group.seasons.count > 5 {
                    Button {
                        stepSeason(proxy, group: group, forward: false)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(group.seasons, id: \.self) { s in
                            Button {
                                withAnimation(.smooth(duration: 0.2)) { selectedSeason = s }
                            } label: {
                                Text("第 \(s) 季")
                                    .font(.system(size: 12.5, weight: current == s ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(current == s ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04))
                                    )
                                    .foregroundStyle(current == s ? Color.primary : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .id(s)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: 420)

                if group.seasons.count > 5 {
                    Button {
                        stepSeason(proxy, group: group, forward: true)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stepSeason(_ proxy: ScrollViewProxy, group: SeriesGroup, forward: Bool) {
        let seasons = group.seasons
        let current = selectedSeason ?? seasons.first ?? 1
        guard let idx = seasons.firstIndex(of: current) else { return }
        let next = min(max(idx + (forward ? 1 : -1), 0), seasons.count - 1)
        guard seasons[next] != current else { return }
        withAnimation(.smooth(duration: 0.2)) {
            selectedSeason = seasons[next]        // ← 关键：箭头要真的切季
            proxy.scrollTo(seasons[next], anchor: .center)
        }
    }

    private func castSection(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演职人员").font(.system(size: 15, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { person in
                        let tile = VStack(spacing: 5) {
                            CastAvatar(path: castImagePath(person.profilePath),
                                       sourceID: posterItem?.sourceID)
                                .id(meta?.artworkRefreshID)
                            Text(person.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if !person.role.isEmpty {
                                Text(person.role)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 66)
                        .contentShape(Rectangle())

                        if let id = person.tmdbID {
                            NavigationLink(value: PersonRoute(id: id, name: person.name,
                                                              profilePath: castImagePath(person.profilePath),
                                                              sourceID: posterItem?.sourceID)) {
                                tile
                            }
                            .buttonStyle(.plain)
                            .help("查看 \(person.name) 的全部作品")
                        } else {
                            tile
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func castImagePath(_ path: String?) -> String? {
        let isLocal = meta?.fieldSources?["cast"] == "nfo"
            || (meta?.fieldSources?["cast"] == nil && meta?.source == "nfo")
        return CachedImageLoader.tmdbPath(path, size: "w185", isSourceRelative: isLocal)
    }

    /// 集标题：nfo 里的 title 只有在跟剧名不同时才用（否则显示文件名更清楚）
    private func episodeTitle(for item: MediaItem, in group: SeriesGroup) -> String? {
        guard let t = metaStore.metadata(for: item.id)?.title, !t.isEmpty else { return nil }
        if t == group.title { return nil }
        if t.hasPrefix(group.title) { return nil }
        if group.title.hasPrefix(t) { return nil }   // nfo 里只写了剧名的情况
        return t
    }

    // MARK: 文件信息

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件信息").font(.system(size: 15, weight: .semibold))
            if let item = posterItem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    Text(item.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let size = item.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - 选集缩略图

private struct EpisodeThumb: View {
    let item: MediaItem
    let record: PlaybackRecord?
    var title: String?
    let width: CGFloat

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                EpisodeStill(item: item)
                Text(String(format: "%02d", item.episode ?? 0))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(5)
                if record?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(5)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .bottom) {
                if let record, record.progress > 0.02, !record.isFinished {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.primary.opacity(0.15))
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * record.progress)
                        }
                    }
                    .frame(height: 2.5)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 5)
                    .padding(.bottom, 4)
                }
            }

            Text(title ?? item.fileName)
                .font(.system(size: 10.5))
                .foregroundStyle(title == nil ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.fileName)
    }

}

// MARK: - Scoped detail metadata action

@MainActor
enum DetailMetadataAction {
    static func currentSeries(_ snapshot: SeriesGroup, in store: AppStore) -> SeriesGroup? {
        let groups = store.seriesGroups
        if let exact = groups.first(where: { $0.id == snapshot.id }) { return exact }
        let itemIDs = Set(snapshot.items.map(\.id))
        return groups.first { group in group.items.contains { itemIDs.contains($0.id) } }
    }

    static func rescanAndLoad(item: MediaItem, series: SeriesGroup?,
                              in store: AppStore) async throws -> MediaItem? {
        if let series { try await store.rescanSeries(series) }
        else { try await store.rescanItem(item) }
        try Task.checkCancellation()
        let affected: MediaItem?
        if let series {
            affected = currentSeries(series, in: store)?.posterItem
        } else {
            affected = store.library.first { $0.id == item.id }
        }
        guard let affected else { return nil }
        if series != nil {
            _ = await MetadataStore.shared.seriesMetadata(for: affected, in: store)
        } else {
            await MetadataStore.shared.load(for: affected, in: store)
        }
        try Task.checkCancellation()
        return affected
    }
}

// MARK: - 演职员头像

private struct CastAvatar: View {
    let path: String?
    let sourceID: UUID?

    var body: some View {
        CachedRemoteImage(path: path, sourceID: sourceID) {
            placeholder
        }
        .frame(width: 60, height: 60)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.primary.opacity(0.10))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
    }

}


// MARK: - 单集剧照（直接读同目录的 -thumb.jpg，不经任何缓存）

private struct EpisodeStill: View {
    let item: MediaItem

    @EnvironmentObject private var store: AppStore
    @State private var image: PlatformImage?
    @State private var tried = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !tried {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: "\(item.id)#r\(store.artworkRevision)") { await load() }
    }

    private func load() async {
        image = nil
        tried = false
        let revision = store.artworkRevision
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else {
            tried = true
            return
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension

        // 同一目录只列一次（10 集共用一个 PROPFIND 结果）
        let names = await StillCache.names(in: dir, source: source, revision: revision)
        guard !Task.isCancelled, revision == store.artworkRevision else { return }
        let candidates = ["\(stem)-thumb.jpg", "\(stem)-thumb.png",
                          "\(stem).jpg", "thumb.jpg", "thumb.png"]
        guard let hit = candidates.compactMap({ candidate in
            names.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }).first else {
            tried = true
            return
        }
        let path = dir.isEmpty ? hit : "\(dir)/\(hit)"

        let cacheKey = "\(item.sourceID.uuidString)#r\(revision)#\(path)"
        if let cached = StillCache.image(cacheKey) {
            image = cached
            tried = true
            return
        }
        if let data = try? await source.data(for: path), let img = PlatformImage(data: data) {
            guard !Task.isCancelled, revision == store.artworkRevision else { return }
            StillCache.store(img, path: cacheKey)
            withAnimation(.easeOut(duration: 0.15)) { image = img }
        } else {
            AppLog.error("EpisodeStill 取图失败：\(path)")
        }
        tried = true
    }
}


/// 单集剧照的共享缓存：目录列表（成功才缓存）+ 已解码图片
@MainActor
enum StillCache {
    private static var listings: [String: [String]] = [:]
    private static var inflight: [String: Task<[String], Never>] = [:]
    private static var images: [String: PlatformImage] = [:]

    static func names(in dir: String, source: MediaSource, revision: Int) async -> [String] {
        let key = "\(source.config.id.uuidString)#r\(revision)#\(dir)"
        if let hit = listings[key] { return hit }
        if let task = inflight[key] { return await task.value }

        let task = Task<[String], Never> {
            guard let entries = try? await source.list(path: dir) else { return [] }
            return entries.filter { !$0.isDirectory }.map(\.name)
        }
        inflight[key] = task
        let names = await task.value
        inflight[key] = nil
        if listings.count > 240 { listings.removeAll() }
        if !names.isEmpty { listings[key] = names }   // 失败/空不缓存
        return names
    }

    static func image(_ path: String) -> PlatformImage? { images[path] }

    static func store(_ image: PlatformImage, path: String) {
        if images.count > 240 { images.removeAll() }
        images[path] = image
    }
}
