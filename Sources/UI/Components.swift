import SwiftUI

// MARK: - 跨平台图片

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - 封面

struct ArtworkView: View {
    let item: MediaItem?
    var cornerRadius: CGFloat = 6
    var variant: ArtworkVariant = .poster

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var artwork: ArtworkStore
    @ObservedObject private var metadata = MetadataStore.shared
    @ObservedObject private var preferences = Preferences.shared
    @State private var image: PlatformImage?
    static var thumbLogCount = 0

    var body: some View {
        ZStack {
            placeholder
            if let image {
                // 横版位缺图时会退回竖版海报：直接铺满会把画面裁得只剩中间一条，
                // 所以竖图改成「模糊底 + 完整居中」，大尺寸头图也不至于糊成一片
                if variant == .backdrop, image.size.width < image.size.height {
                    ZStack {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 30)
                            .overlay(Color.black.opacity(0.25))
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    .transition(.opacity)
                } else {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: taskIdentity) {
            let identity = taskIdentity
            guard let item else { image = nil; return }
            // 先查内存再清空，命中时不会先闪一下占位图
            if let hit = artwork.cached(for: item, variant: variant, in: store) {
                guard !Task.isCancelled, identity == taskIdentity else { return }
                image = hit
                return
            }
            image = nil
            let loaded = await artwork.image(for: item, variant: variant, in: store)
            guard !Task.isCancelled, identity == taskIdentity else { return }
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }

    private var taskIdentity: String {
        guard let item else { return "empty" }
        // Core's key includes artworkMetadata paths/provenance and both backdrop/poster fallback.
        let cacheIdentity = artwork.requestIdentity(for: item, variant: variant, in: store)
        // 封面 URL 会在图片下载落盘后从远端地址切到 file URL，借此触发一次重载；
        // validImage(at:) 已按 (mtime,size) 记忆化，这里每张卡片只剩 stat，不再整图读盘解码。
        let url: String
        switch variant {
        case .backdrop:   // 横版缺图会回退竖版海报，两者都要参与
            url = (metadata.backdropURL(for: item)?.absoluteString ?? "") + "|"
                + (metadata.cachedPosterURL(for: item)?.absoluteString ?? "")
        case .poster, .thumb: url = metadata.cachedPosterURL(for: item)?.absoluteString ?? ""
        }
        return "\(cacheIdentity)#\(url)"
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(gradient)
            .overlay {
                Image(systemName: (item?.seriesTitle != nil) ? "tv" : "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
    }

    private var gradient: LinearGradient {
        let seed = abs((item?.id ?? "x").hashValue % 6)
        let palettes: [[Color]] = [
            [Color(red: 0.17, green: 0.20, blue: 0.29), Color(red: 0.08, green: 0.09, blue: 0.13)],
            [Color(red: 0.24, green: 0.16, blue: 0.20), Color(red: 0.10, green: 0.08, blue: 0.11)],
            [Color(red: 0.13, green: 0.23, blue: 0.23), Color(red: 0.07, green: 0.11, blue: 0.11)],
            [Color(red: 0.26, green: 0.21, blue: 0.13), Color(red: 0.11, green: 0.09, blue: 0.07)],
            [Color(red: 0.18, green: 0.17, blue: 0.27), Color(red: 0.08, green: 0.08, blue: 0.13)],
            [Color(red: 0.22, green: 0.14, blue: 0.14), Color(red: 0.10, green: 0.07, blue: 0.07)]
        ]
        return LinearGradient(colors: palettes[seed], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Persistent remote and source-relative images

@MainActor
enum CachedImageLoader {
    static func cached(path: String, sourceID: UUID) -> PlatformImage? {
        let file = MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: path, sourceID: sourceID))
        guard let data = try? Data(contentsOf: file), MetadataCache.validImage(data) else { return nil }
        return PlatformImage(data: data)
    }

    static func load(path: String, source: MediaSource?,
                     shouldCommit: @escaping @MainActor () -> Bool) async -> PlatformImage? {
        let sourceID = source?.config.id ?? remoteSourceID
        if let source {
            do {
                try await MetadataImageCache.shared.persist(path: path, source: source,
                                                           shouldCommit: shouldCommit)
            } catch {
                if !Task.isCancelled, shouldCommit() {
                    AppLog.info("Image cache: \(error.localizedDescription)")
                }
            }
        } else if cached(path: path, sourceID: sourceID) == nil,
                  let url = URL(string: path),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, shouldCommit(),
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      MetadataCache.validImage(data) else { return nil }
                let file = MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: path, sourceID: sourceID))
                try data.write(to: file, options: .atomic)
            } catch { return nil }
        }
        guard !Task.isCancelled, shouldCommit() else { return nil }
        return cached(path: path, sourceID: sourceID)
    }

    static let remoteSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func tmdbPath(_ path: String?, size: String, isSourceRelative: Bool = false) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if isSourceRelative || path.hasPrefix("http") { return path }
        return "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? "" : "/")\(path)"
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    let path: String?
    var sourceID: UUID?
    @ViewBuilder var placeholder: () -> Placeholder

    @EnvironmentObject private var store: AppStore
    @State private var image: PlatformImage?

    private struct Request: Equatable {
        let path: String?
        let source: MediaSourceConfig?
        let revision: Int
    }

    private var request: Request {
        Request(path: path, source: sourceID.flatMap { store.source(for: $0) },
                revision: store.artworkRevision)
    }

    var body: some View {
        ZStack {
            placeholder()
            if let image { Image(platformImage: image).resizable().scaledToFill() }
        }
        .task(id: request) {
            let captured = request
            image = nil
            guard let path = captured.path else { return }
            let id = captured.source?.id ?? CachedImageLoader.remoteSourceID
            image = CachedImageLoader.cached(path: path, sourceID: id)
            let source = captured.source.flatMap { try? MediaSourceFactory.make($0) }
            let loaded = await CachedImageLoader.load(path: path, source: source) {
                request == captured
            }
            guard !Task.isCancelled, request == captured else { return }
            if let loaded { image = loaded }
        }
    }
}

#if os(iOS)
/// 顶栏的连体分段控件：一个 material 胶囊里排布按钮，选中块用 matchedGeometryEffect 滑动。
struct BrowseSegmentedControl: View {
    let destinations: [BrowseDestination]
    let selection: BrowseDestination?
    let identifierPrefix: String
    let onSelect: (BrowseDestination) -> Void

    @Namespace private var selectionNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(destinations, id: \.self) { destination in
                let selected = selection == destination
                Button {
                    withAnimation(.smooth(duration: 0.28)) { onSelect(destination) }
                } label: {
                    Text(destination.title)
                        .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "segmented.selection", in: selectionNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.title)
                .accessibilityIdentifier("\(identifierPrefix).\(destination.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.10)))
        .animation(.smooth(duration: 0.28), value: selection)
    }
}

/// 顶栏右上角的搜索按钮：material 圆形底，保证在深浅头图上都清晰。
struct SearchToolbarButton: View {
    let action: () -> Void
    var identifier = "library.search"

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
        .accessibilityIdentifier(identifier)
    }
}
#endif

// MARK: - 海报单元（无边框、标题在下方 —— 对齐 VidHub 的网格观感）

struct PosterTile: View {
    let title: String
    var subtitle: String?
    var item: MediaItem?
    var badge: String?
    var progress: Double?
    var width: CGFloat?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkView(item: item, cornerRadius: 6)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0.02, progress < 0.98 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(.white).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 2.5)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                    }
                }
                .overlay {
                    if hovering {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.black.opacity(0.18))
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                    }
                }

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - 列表筛选

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, unwatched, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:       return "全部"
        case .unwatched: return "未观看"
        case .recent:    return "最近添加"
        }
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let t = actionTitle, let a = action {
                Button(t, action: a).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

// MARK: - 页面底色 / 大图淡出（详情页与首页轮播共用）

extension Color {
    /// 页面底色：跟窗口背景一致。大图淡出时用它收尾，才不会出现"黑渐变接白底"的硬边
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

enum HeroFade {
    /// smoothstep 采样：alpha 从 1 平滑收到 0，把大图"化"进页面底色
    static func gradient(start: Double, steps: Int = 20) -> LinearGradient {
        let stops: [Gradient.Stop] = (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            return .init(color: .white.opacity(1 - eased), location: start + (1 - start) * t)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// 大图上的三层压暗：顶部（工具栏/返回键）、左侧（标题列）、底部（信息区）
struct HeroScrims: View {
    var strength: Double = 1.0

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0.0),
                    .init(color: .black.opacity(0.12), location: 0.14),
                    .init(color: .clear, location: 0.30)
                ],
                startPoint: .top, endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.50 * strength), location: 0.0),
                    .init(color: .black.opacity(0.28 * strength), location: 0.32),
                    .init(color: .black.opacity(0.08 * strength), location: 0.62),
                    .init(color: .clear, location: 0.88)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .mask(HeroFade.gradient(start: 0.80))

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.24),
                    .init(color: .black.opacity(0.20 * strength), location: 0.48),
                    .init(color: .black.opacity(0.48 * strength), location: 0.70),
                    .init(color: .black.opacity(0.52 * strength), location: 0.86),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

/// 整页背景：同一张剧照模糊 + 压暗，正文就浮在这层上面。
/// 头图用锐利版本，往下淡出 → 自然过渡成"虚化背景"，中间没有硬边。
struct BlurredBackdrop: View {
    let item: MediaItem?
    var scheme: ColorScheme = .dark
    var radius: CGFloat = 42

    private var isDark: Bool { scheme == .dark }
    /// 深色主题压黑，浅色主题压白 —— 正文用的是 .primary，两种主题下都得压得住
    private var wash: Color { isDark ? .black : .white }
    private var washOpacity: Double { isDark ? 0.62 : 0.78 }

    var body: some View {
        GeometryReader { proxy in
            ArtworkView(item: item, cornerRadius: 0, variant: .backdrop)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .blur(radius: radius, opaque: true)
                .overlay(wash.opacity(washOpacity))
                .overlay {
                    // 往下再压一层，正文区域对比度更稳
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: wash.opacity(0.16), location: 0.55),
                            .init(color: wash.opacity(0.34), location: 1.0)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 视口尺寸

struct ViewportSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

extension View {
    /// 量出自己所在区域的尺寸（滚动视图视口），头图高度靠它自适应
    func measureViewport(_ handler: @escaping (CGSize) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ViewportSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(ViewportSizeKey.self) { size in
            if size.width > 0, size.height > 0 { handler(size) }
        }
    }
}

// MARK: - 轮播图（媒体库顶部 hero：大图 + 跟下方模块平滑过渡）

struct HeroCarousel: View {
    let entries: [BrowseEntry]
    /// 高度由调用方按视口算好传进来
    var height: CGFloat = 420
    /// 把当前这一条的封面回传给页面，用来铺整页的虚化背景
    @Binding var currentItem: MediaItem?

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerPresenter
    @Environment(\.colorScheme) private var colorScheme

    @State private var index = 0
    @State private var timer: Task<Void, Never>?

    var body: some View {
        #if os(iOS)
        TabView(selection: $index) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                ZStack(alignment: .bottomLeading) {
                    backdrop(for: entry)
                    info(for: entry)
                        .padding(.horizontal, 32)
                        .padding(.bottom, max(54, height * 0.14))
                }
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("library.carousel")
        .overlay { dots }
        .frame(height: height)
        .onAppear { syncCurrent(); startAutoAdvance() }
        .onDisappear { timer?.cancel() }
        .onChange(of: index) { _, _ in syncCurrent(); startAutoAdvance() }
        .onChange(of: entries.map(\.id)) { _, _ in
            index = min(index, max(0, entries.count - 1))
            syncCurrent()
            startAutoAdvance()
        }
        #else
        ZStack(alignment: .bottomLeading) {
            if entries.indices.contains(index) {
                let entry = entries[index]

                backdrop(for: entry)
                    .id(entry.id)

                info(for: entry)
                    .padding(.horizontal, 40)
                    .padding(.bottom, max(54, height * 0.14))

                dots
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onAppear {
            syncCurrent()
            startAutoAdvance()
        }
        .onDisappear { timer?.cancel() }
        .onChange(of: index) { _, _ in syncCurrent() }
        #endif
    }

    private func syncCurrent() {
        guard entries.indices.contains(index) else { return }
        let item = entries[index].posterItem
        if item?.id != currentItem?.id { currentItem = item }
    }

    /// 跟详情页同一套：横版剧照 + 压暗层 + 下缘淡出（淡出到整页的虚化背景上）
    private func backdrop(for entry: BrowseEntry) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let strength: Double = colorScheme == .dark ? 1.0 : 1.5
            ZStack {
                ArtworkView(item: entry.posterItem, cornerRadius: 0, variant: .backdrop)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .mask(HeroFade.gradient(start: 0.70))

                HeroScrims(strength: strength)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func info(for entry: BrowseEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 2)

            if let sub = entry.subtitle {
                Text(sub)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.82))
                    .shadow(color: .black.opacity(0.4), radius: 8)
            }

            HStack(spacing: 10) {
                Button { play(entry) } label: {
                    Label("播放", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 120, height: 34)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)

                #if os(macOS)
                Button { index = (index + 1) % max(1, entries.count) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.16), in: Circle())
                        .foregroundStyle(.white)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                #endif
            }
            .padding(.top, 2)
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(1, min(entries.count, 8)), id: \.self) { i in
                Capsule()
                    .fill(i == index % 8 ? Color.white : Color.white.opacity(0.35))
                    .frame(width: i == index % 8 ? 14 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 40)
        .padding(.bottom, 26)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("轮播图页码")
        .accessibilityValue("\(index + 1)/\(entries.count)")
        .accessibilityIdentifier("library.carousel.page")
    }

    private func play(_ entry: BrowseEntry) {
        switch entry {
        case .movie(let m):
            player.play(m)
        case .series(let s):
            if let next = s.nextEpisode(progress: store.progress) { player.play(next) }
        }
    }

    private func startAutoAdvance() {
        timer?.cancel()
        guard entries.count > 1 else { return }
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        index = (index + 1) % entries.count
                    }
                }
            }
        }
    }
}

// MARK: - Liquid Glass 兼容层
/// macOS/iOS 26 才有真 Liquid Glass；低版本退回材质，保证 14+ 能编译运行。
extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
