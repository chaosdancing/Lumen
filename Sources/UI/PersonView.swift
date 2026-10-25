import SwiftUI

// MARK: - 演员页

struct PersonRoute: Hashable {
    let id: Int
    let name: String
}

struct PersonCredit: Identifiable {
    let id: String
    let tmdbID: Int
    let title: String
    let year: String?
    let posterPath: String?
    let isTV: Bool
    let role: String?
}

struct PersonView: View {
    let route: PersonRoute

    @EnvironmentObject private var store: AppStore
    @State private var credits: [PersonCredit] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var profilePath: String?

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
                                   message: "TMDB 上这个演员没有可显示的作品。",
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
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let url = profileURL(profilePath) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFill() }
                        else { avatarPlaceholder }
                    }
                } else {
                    avatarPlaceholder
                }
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
        let matched = matchedItem(for: credit)
        let content = VStack(alignment: .leading, spacing: 5) {
            Group {
                if let url = posterURL(credit.posterPath) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
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
            NavigationLink(value: DetailTarget.movie(matched)) { content }
                .buttonStyle(.plain)
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

    private func matchedItem(for credit: PersonCredit) -> MediaItem? {
        let target = TMDBClient.searchableTitle(credit.title).lowercased()
        guard !target.isEmpty else { return nil }
        return store.library.first { item in
            let t = TMDBClient.searchableTitle(item.title).lowercased()
            return t == target
        }
    }

    private func posterURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }

    private func profileURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(path)")
    }

    // MARK: 数据

    private func load() async {
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
            let (data, _) = try await URLSession.shared.data(for: request)
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
            // 有海报的排前面，再按年份倒序
            credits = list.sorted {
                if ($0.posterPath != nil) != ($1.posterPath != nil) { return $0.posterPath != nil }
                return ($0.year ?? "") > ($1.year ?? "")
            }
            AppLog.info("演员页 \(route.name)（\(route.id)）→ \(credits.count) 部")
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppLog.error("演员页失败：\(error.logDescription)")
        }
    }
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
        .task(id: "\(seriesItem?.id ?? "-")#s\(season)") { await load() }
    }

    private func load() async {
        guard let item = seriesItem else { return }

        // 1) 本地 seasonNN-poster.jpg
        if let path = await LocalArtworkResolver.shared.seasonPosterPath(for: item, season: season, in: store),
           let data = try? await store.data(for: item, path: path),
           let img = PlatformImage(data: data) {
            image = img
            return
        }
        // 2) TMDB 季海报
        if let url = await MetadataStore.shared.seasonPosterURL(seriesItemID: item.id, season: season),
           let data = try? await URLSession.shared.data(from: url).0,
           let img = PlatformImage(data: data) {
            image = img
        }
    }
}
