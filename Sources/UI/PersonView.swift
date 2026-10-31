import SwiftUI

// MARK: - 演员页

struct PersonRoute: Hashable {
    let id: Int
    let name: String
    var profilePath: String? = nil
    var sourceID: UUID? = nil
}

struct PersonCredit: Identifiable {
    let id: String
    let tmdbID: Int
    let title: String
    let year: String?
    let posterPath: String?
    let isTV: Bool
    let role: String?
    var sourceID: UUID? = nil
    var localTarget: DetailTarget? = nil
}

struct PersonView: View {
    let route: PersonRoute

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metaStore = MetadataStore.shared
    @State private var credits: [PersonCredit] = []
    @State private var loading = true
    @State private var errorText: String?

    private let grid = [GridItem(.adaptive(minimum: 112, maximum: 146), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if loading {
                    ProgressView().controlSize(.small).padding(.top, 30)
                } else if let errorText {
                    EmptyStateView(symbol: "person.crop.circle.badge.exclamationmark",
                                   title: "没取到参演作品", message: errorText,
                                   actionTitle: "重试", action: { Task { await load() } })
                } else if credits.isEmpty {
                    EmptyStateView(symbol: "film", title: "没有参演记录",
                                   message: "当前媒体库里没有这位演员的参演作品。",
                                   actionTitle: nil, action: nil)
                } else {
                    LazyVGrid(columns: grid, alignment: .leading, spacing: 16) {
                        ForEach(credits) { credit in
                            creditTile(credit)
                        }
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle(route.name)
        .task(id: route) { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CachedRemoteImage(path: route.profilePath, sourceID: route.sourceID) {
                avatarPlaceholder
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(route.name).font(.system(size: 20, weight: .bold))
                Text("\(credits.count) 部参演作品")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var avatarPlaceholder: some View {
        Circle().fill(Color.primary.opacity(0.10))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func creditTile(_ credit: PersonCredit) -> some View {
        let matched = credit.localTarget ?? matchedTarget(for: credit)
        let content = VStack(alignment: .leading, spacing: 5) {
            CachedRemoteImage(path: CachedImageLoader.tmdbPath(credit.posterPath, size: "w342"),
                              sourceID: credit.sourceID ?? route.sourceID) {
                placeholder
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(credit.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            HStack(spacing: 5) {
                if credit.isTV {
                    Text("剧集").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let y = credit.year {
                    Text(y).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())

        if let matched {
            TileTap(target: matched) { content }
        } else {
            content.opacity(0.85)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.07))
            .overlay {
                Image(systemName: "film").font(.system(size: 18)).foregroundStyle(.tertiary)
            }
    }

    private func matchedTarget(for credit: PersonCredit) -> DetailTarget? {
        func normalized(_ title: String) -> String {
            TMDBClient.searchableTitle(title).lowercased()
        }
        let title = normalized(credit.title)
        let year = credit.year.flatMap { Int($0) }
        func matchesTitle(_ titles: [String], years: [Int]) -> Bool {
            guard !title.isEmpty, titles.contains(where: { normalized($0) == title }) else { return false }
            return year == nil || years.allSatisfy { $0 == year }
        }

        if credit.isTV {
            let groups = store.seriesGroups
            func metadata(_ group: SeriesGroup) -> [MediaMetadata] {
                group.posterItem.flatMap { metaStore.cachedSeriesMetadata(for: $0) }.map { [$0] } ?? []
            }
            // IDs win over title fallbacks, including translated/localized titles.
            if let group = groups.first(where: {
                metadata($0).contains { $0.tmdbID == credit.tmdbID }
            }) { return .series(group) }
            return groups.first { group in
                let meta = metadata(group)
                guard meta.allSatisfy({ $0.tmdbID == nil }) else { return false }
                let titles = [group.title] + group.items.compactMap(\.seriesTitle)
                    + meta.flatMap { [$0.title, $0.originalTitle, $0.seriesTitle].compactMap { $0 } }
                let releaseYears = meta
                    .compactMap { $0.releaseDate.flatMap { Int($0.prefix(4)) } }
                return matchesTitle(titles, years: releaseYears)
            }.map { .series($0) }
        } else {
            let movies = store.movieItems
            if let item = movies.first(where: {
                metaStore.metadata(for: $0.id)?.tmdbID == credit.tmdbID
            }) { return .movie(item) }
            return movies.first { item in
                let meta = metaStore.metadata(for: item.id)
                guard meta?.tmdbID == nil else { return false }
                let titles = [item.title] + [meta?.title, meta?.originalTitle].compactMap { $0 }
                let releaseYear = meta?.releaseDate.flatMap { Int($0.prefix(4)) }
                return matchesTitle(titles, years: [item.year, releaseYear].compactMap { $0 })
            }.map { .movie($0) }
        }
    }

    // MARK: 数据

    private func load() async {
        #if os(macOS)
        await loadLocal()
        #else
        await loadRemote()
        #endif
    }

    /// macOS：演员作品完全从本地库计算：扫描已缓存元数据的 cast，不再请求 TMDB。
    private func loadLocal() async {
        loading = true
        defer { loading = false }
        errorText = nil

        func containsPerson(_ cast: [CastMember]) -> Bool {
            cast.contains { member in
                if let id = member.tmdbID, id == route.id { return true }
                return !route.name.isEmpty && member.name == route.name
            }
        }
        func role(in cast: [CastMember]) -> String? {
            cast.first { member in
                (member.tmdbID != nil && member.tmdbID == route.id) || member.name == route.name
            }?.role
        }

        var list: [PersonCredit] = []
        var seen = Set<String>()

        for item in store.movieItems {
            guard let meta = metaStore.metadata(for: item.id),
                  containsPerson(meta.cast) else { continue }
            let key = "movie-\(item.id)"
            guard seen.insert(key).inserted else { continue }
            let year = meta.releaseDate.flatMap { $0.split(separator: "-").first.map(String.init) }
                ?? item.year.map(String.init)
            list.append(PersonCredit(id: key,
                                     tmdbID: meta.tmdbID ?? route.id,
                                     title: meta.title ?? item.title,
                                     year: year,
                                     posterPath: meta.posterPath,
                                     isTV: false,
                                     role: role(in: meta.cast),
                                     sourceID: item.sourceID,
                                     localTarget: .movie(item)))
        }

        for group in store.seriesGroups {
            guard let poster = group.posterItem else { continue }
            let meta = metaStore.cachedSeriesMetadata(for: poster)
                ?? metaStore.metadata(for: poster.id)
            guard let meta, containsPerson(meta.cast) else { continue }
            let key = "series-\(group.id)"
            guard seen.insert(key).inserted else { continue }
            let year = meta.releaseDate.flatMap { $0.split(separator: "-").first.map(String.init) }
                ?? poster.year.map(String.init)
            list.append(PersonCredit(id: key,
                                     tmdbID: meta.tmdbID ?? route.id,
                                     title: meta.title ?? group.title,
                                     year: year,
                                     posterPath: meta.posterPath,
                                     isTV: true,
                                     role: role(in: meta.cast),
                                     sourceID: poster.sourceID,
                                     localTarget: .series(group)))
        }

        credits = list.sorted {
            if ($0.posterPath != nil) != ($1.posterPath != nil) { return $0.posterPath != nil }
            if $0.year != $1.year { return ($0.year ?? "") > ($1.year ?? "") }
            return $0.id < $1.id
        }
        AppLog.info("演员页（本地）\(route.name) → \(credits.count) 部")
    }

    #if !os(macOS)
    /// iPad/iPhone 继续使用 TMDB 完整作品列表。
    private func loadRemote() async {
        loading = true
        errorText = nil
        defer { loading = false }

        guard let key = TMDBClient.apiKey else {
            errorText = "需要先配置 TMDB API Key（设置 → 资源）"
            return
        }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/person/\(route.id)/combined_credits")!
        var qs: [URLQueryItem] = [.init(name: "language", value: TMDBClient.language)]
        if !TMDBClient.isReadAccessToken(key) { qs.append(.init(name: "api_key", value: key)) }
        comps.queryItems = qs
        guard let url = comps.url else { return }

        var request = URLRequest(url: url)
        if TMDBClient.isReadAccessToken(key) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw SourceError.invalidResponse("无法读取演员作品")
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorText = "返回内容无法解析"
                return
            }
            let cast = (root["cast"] as? [[String: Any]]) ?? []
            var seen = Set<String>()
            var list: [PersonCredit] = []
            for c in cast {
                guard let id = c["id"] as? Int else { continue }
                let isTV = (c["media_type"] as? String) == "tv"
                let title = (c["title"] as? String) ?? (c["name"] as? String) ?? ""
                guard !title.isEmpty else { continue }
                let key = "\(isTV)-\(id)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let date = (c["release_date"] as? String) ?? (c["first_air_date"] as? String)
                list.append(PersonCredit(id: key,
                                         tmdbID: id,
                                         title: title,
                                         year: date?.prefix(4).description,
                                         posterPath: c["poster_path"] as? String,
                                         isTV: isTV,
                                         role: c["character"] as? String))
            }
            credits = list.sorted {
                if ($0.posterPath != nil) != ($1.posterPath != nil) { return $0.posterPath != nil }
                if $0.year != $1.year { return ($0.year ?? "") > ($1.year ?? "") }
                return $0.id < $1.id
            }
            AppLog.info("演员页 \(route.name)（\(route.id)）→ \(credits.count) 部")
        } catch {
            guard !Task.isCancelled else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("演员页失败：\(error.logDescription)")
        }
    }
    #endif

}

// MARK: - 季海报缩略图（本地 seasonNN-poster.jpg 优先，其次 TMDB）

struct SeasonPosterView: View {
    let seriesItem: MediaItem?
    let season: Int
    var width: CGFloat = 54

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var artwork: ArtworkStore
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.08))
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .task(id: "\(seriesItem?.id ?? "-")#s\(season)#r\(store.artworkRevision)") { await load() }
    }

    private func load() async {
        image = nil
        let revision = store.artworkRevision
        guard let item = seriesItem else { return }

        // 1) 本地 seasonNN-poster.jpg
        if let path = await LocalArtworkResolver.shared.seasonPosterPath(for: item, season: season, in: store),
           let data = try? await store.data(for: item, path: path),
           let img = PlatformImage(data: data) {
            guard !Task.isCancelled, revision == store.artworkRevision else { return }
            image = img
            return
        }
        // 2) TMDB 季海报
        if let url = await MetadataStore.shared.seasonPosterURL(seriesItemID: item.id, season: season),
           let data = try? await URLSession.shared.data(from: url).0,
           let img = PlatformImage(data: data) {
            guard !Task.isCancelled, revision == store.artworkRevision else { return }
            image = img
        }
    }
}
