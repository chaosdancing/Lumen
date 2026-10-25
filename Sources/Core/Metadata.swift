import Foundation

// MARK: - 元数据模型

struct CastMember: Codable, Hashable, Identifiable {
    var id: String { "\(tmdbID ?? 0)-\(name)-\(role)" }
    var tmdbID: Int?
    var name: String
    var role: String
    var profilePath: String?
}

struct MediaMetadata: Codable {
    var itemID: String
    var tmdbID: Int?
    /// 剧名（TMDB 的 name / 电影标题）。用于把同一部剧的多个目录归并到一起。
    var seriesTitle: String?
    var title: String?
    var originalTitle: String?
    var overview: String?
    var rating: Double?          // 0...10
    var voteCount: Int?
    var genres: [String] = []
    var cast: [CastMember] = []
    var posterPath: String?      // TMDB 相对路径 或 本地图片路径
    var backdropPath: String?
    var releaseDate: String?
    var matchedName: String?
    var source: String = "tmdb"  // tmdb | nfo
    var updatedAt: Date = Date()
}

// MARK: - 元数据仓库（刮削 + 缓存）

@MainActor
final class MetadataStore: ObservableObject {
    static let shared = MetadataStore()

    @Published private(set) var items: [String: MediaMetadata] = [:]
    /// 剧集级缓存：同一部剧的多个 episode 只查一次 TMDB
    private var seriesCache: [String: MediaMetadata] = [:]
    @Published private(set) var inFlight: Set<String> = []
    @Published var lastError: String?

    private var cacheDir: URL {
        let dir = StorePaths.root.appendingPathComponent("Metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { loadAllFromDisk() }

    // MARK: 读取

    func metadata(for itemID: String) -> MediaMetadata? { items[itemID] }

    func cachedPosterURL(for itemID: String) -> URL? {
        guard let meta = items[itemID], let path = meta.posterPath else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let key = TMDBClient.apiKey else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    func backdropURL(for itemID: String) -> URL? {
        guard let meta = items[itemID], let path = meta.backdropPath else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        guard TMDBClient.apiKey != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }

    // MARK: 刮削

    /// 单个条目：优先本地 .nfo，其次 TMDB。已有缓存则跳过。
    func load(for item: MediaItem, in store: AppStore, force: Bool = false) async {
        if !force, items[item.id] != nil { return }
        if inFlight.contains(item.id) { return }
        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        // 剧集：先看同剧是否已刮过，直接复用（省掉 74 集查 74 次）
        if let seriesKey = Self.seriesKey(for: item),
           let cached = seriesCache[seriesKey] {
            var copy = cached
            copy.itemID = item.id
            items[item.id] = copy
            saveToDisk(copy)
            AppLog.info("  ← 复用剧集缓存「\(seriesKey)」→ \(copy.title ?? "-")")
            return
        }

        let preferNFO = Preferences.shared.preferNFO
        let hasKey = TMDBClient.apiKey != nil
        AppLog.info("刮削 \"\(item.title)\" preferNFO=\(preferNFO) hasKey=\(hasKey) dir=\((item.path as NSString).deletingLastPathComponent)")

        // 1) 设置里勾了"优先使用NFO"就先读本地
        if preferNFO {
            if let nfo = await NFOParser.metadata(for: item, in: store) {
                items[item.id] = nfo
                saveToDisk(nfo)
                AppLog.info("  ← NFO 命中：title=\(nfo.title ?? "-") rating=\(nfo.rating.map { String($0) } ?? "-")")
                return
            }
            AppLog.info("  ← NFO 未找到")
        }

        // 2) TMDB
        if hasKey {
            do {
                let isSeries = item.seriesTitle != nil
                let query = isSeries ? (item.seriesTitle ?? item.title) : item.title
                if let meta = try await TMDBClient.shared.scrape(itemID: item.id,
                                                                query: query,
                                                                year: item.year,
                                                                isSeries: isSeries) {
                    items[item.id] = meta
                    saveToDisk(meta)
                    if let key = Self.seriesKey(for: item) { seriesCache[key] = meta }
                    AppLog.info("  ← TMDB 命中：\(meta.title ?? "-")")
                    return
                }
                AppLog.info("  ← TMDB 无结果：\(query)")
            } catch {
                lastError = error.localizedDescription
                AppLog.error("  ← TMDB 失败：\(error.logDescription)")
            }
        }

        // 3) 兜底：本地 NFO
        if let nfo = await NFOParser.metadata(for: item, in: store) {
            items[item.id] = nfo
            saveToDisk(nfo)
            AppLog.info("  ← 兜底 NFO 命中：\(nfo.title ?? "-")")
        } else {
            AppLog.info("  ← 无元数据（既没有 nfo 也没刮到）")
        }
    }

    /// 剧集归一化键：去掉季号，用于同剧复用
    private static func seriesKey(for item: MediaItem) -> String? {
        guard let series = item.seriesTitle else { return nil }
        let cleaned = TMDBClient.searchableTitle(series).lowercased()
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 批量刮削（扫描完成后调用）
    func scrapeAll(items list: [MediaItem], in store: AppStore, limit: Int = 40) async {
        guard TMDBClient.apiKey != nil else { return }
        let pending = list.filter { items[$0.id] == nil }
        for item in pending.prefix(limit) {
            await load(for: item, in: store)
            try? await Task.sleep(nanoseconds: 260_000_000)   // 限速，TMDB 40 req/s
        }
    }

    /// 季海报（本地没有时用 TMDB 的季海报）
    func seasonPosterURL(seriesItemID: String, season: Int) async -> URL? {
        guard let meta = items[seriesItemID], let tvID = meta.tmdbID,
              let key = TMDBClient.apiKey else { return nil }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/tv/\(tvID)/season/\(season)")!
        var items: [URLQueryItem] = [.init(name: "language", value: TMDBClient.language)]
        if !TMDBClient.isReadAccessToken(key) { items.append(.init(name: "api_key", value: key)) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        if TMDBClient.isReadAccessToken(key) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = root["poster_path"] as? String else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    // MARK: 磁盘

    private func saveToDisk(_ meta: MediaMetadata) {
        let url = cacheDir.appendingPathComponent(Self.fileName(meta.itemID))
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadAllFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir,
                                                                      includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let meta = try? decoder.decode(MediaMetadata.self, from: data) {
                items[meta.itemID] = meta
            }
        }
    }

    private static func fileName(_ id: String) -> String {
        let digest = SHA256Lite.hash(id)
        return digest + ".json"
    }
}

// MARK: - 本地 .nfo 解析（Kodi / Emby 生成的元数据文件）

enum NFOParser {
    @MainActor
    static func metadata(for item: MediaItem, in store: AppStore) async -> MediaMetadata? {
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else { return nil }
        let dir = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let entries = try? await source.list(path: dir) else {
            AppLog.error("NFO: 列目录失败 \(dir)")
            return nil
        }
        let names = Set(entries.filter { !$0.isDirectory }.map { $0.name.lowercased() })

        // 单集 .nfo 或整剧 tvshow.nfo
        let candidates = ["\(stem).nfo", "movie.nfo", "tvshow.nfo"]
        guard let nfoName = candidates.first(where: { names.contains($0.lowercased()) }) else {
            let nfos = names.filter { $0.hasSuffix(".nfo") }
            AppLog.info("NFO: \(dir) 里没找到 \(candidates)，该目录 nfo=\(nfos.isEmpty ? "无" : nfos.joined(separator: ","))")
            return nil
        }
        let path = dir.isEmpty ? nfoName : "\(dir)/\(nfoName)"
        guard let data = try? await source.data(for: path) else { return nil }
        let text = SubtitleParser.decodeText(data)

        func tag(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>") else { return nil }
            // 闭合标签必须从起始标签之后开始找，否则区间非法会直接崩
            guard let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex),
                  start.upperBound <= end.lowerBound else { return nil }
            let value = text[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        var meta = MediaMetadata(itemID: item.id)
        meta.source = "nfo"
        meta.title = tag("title")
        meta.originalTitle = tag("originaltitle")
        meta.overview = tag("plot") ?? tag("outline")
        meta.releaseDate = tag("year") ?? tag("premiered")
        if let r = tag("rating"), let v = Double(r) { meta.rating = v }
        meta.genres = matches(text, tag: "genre")

        // <actor><name>..</name><role>..</role></actor>
        var cast: [CastMember] = []
        var rest = Substring(text)
        while let s = rest.range(of: "<actor>"),
              let e = rest.range(of: "</actor>", range: s.upperBound..<rest.endIndex),
              s.upperBound <= e.lowerBound {
            let block = rest[s.upperBound..<e.lowerBound]
            let name = block.range(of: "<name>").flatMap { ns in
                block.range(of: "</name>", range: ns.upperBound..<block.endIndex).map {
                    String(block[ns.upperBound..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let role = block.range(of: "<role>").flatMap { rs in
                block.range(of: "</role>", range: rs.upperBound..<block.endIndex).map {
                    String(block[rs.upperBound..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let name, !name.isEmpty {
                cast.append(CastMember(name: name, role: role ?? "", profilePath: nil))
            }
            rest = rest[e.upperBound...]
        }
        meta.cast = Array(cast.prefix(20))

        // 本地图片：<thumb>poster.jpg</thumb> 或同目录 poster.jpg
        if let thumb = tag("thumb"), names.contains(thumb.lowercased()) {
            meta.posterPath = dir.isEmpty ? thumb : "\(dir)/\(thumb)"
        } else if names.contains("poster.jpg") {
            meta.posterPath = dir.isEmpty ? "poster.jpg" : "\(dir)/poster.jpg"
        }
        return meta
    }

    private static func matches(_ text: String, tag: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let s = rest.range(of: "<\(tag)>"),
              let e = rest.range(of: "</\(tag)>", range: s.upperBound..<rest.endIndex),
              s.upperBound <= e.lowerBound {
            let v = String(rest[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out.append(v) }
            rest = rest[e.upperBound...]
        }
        return out
    }
}

// MARK: - TMDB

enum TMDBError: LocalizedError {
    case noKey
    case badResponse(Int)
    case decode
    var errorDescription: String? {
        switch self {
        case .noKey:              return "还没有配置 TMDB API Key（设置 → 元数据）"
        case .badResponse(let c): return "TMDB 返回 \(c)，检查 Key 是否正确"
        case .decode:             return "TMDB 返回内容无法解析"
        }
    }
}

final class TMDBClient {
    static let shared = TMDBClient()

    private static let keyAccount = "tmdb.api.key"
    private static let languageKey = "tmdb.language"

    static var apiKey: String? {
        #if DEBUG
        let v = UserDefaults.standard.string(forKey: keyAccount)
        #else
        let v = Keychain.get(account: keyAccount)
        #endif
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    static func setAPIKey(_ key: String) {
        #if DEBUG
        UserDefaults.standard.set(key.isEmpty ? nil : key, forKey: keyAccount)
        #else
        if key.isEmpty { Keychain.delete(account: keyAccount) }
        else { Keychain.set(key, account: keyAccount) }
        #endif
    }

    /// TMDB 有两种凭据：
    /// - API 密钥（v3 auth）：32 位十六进制，走 `?api_key=`
    /// - API 读访问令牌（v4 auth）：JWT，以 `eyJ` 开头，走 `Authorization: Bearer`
    static func isReadAccessToken(_ key: String) -> Bool {
        key.hasPrefix("eyJ") && key.contains(".")
    }

    static var language: String {
        UserDefaults.standard.string(forKey: languageKey) ?? "zh-CN"
    }

    static func setLanguage(_ lang: String) {
        UserDefaults.standard.set(lang, forKey: languageKey)
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: 刮削

    func scrape(itemID: String, query: String, year: Int?, isSeries: Bool) async throws -> MediaMetadata? {
        guard let key = Self.apiKey else { throw TMDBError.noKey }
        let variants = Self.queryVariants(query)
        guard !variants.isEmpty else { return nil }
        AppLog.info("    TMDB 查询变体：\(variants)")

        // 1) 搜索
        var comps = URLComponents(string: "https://api.themoviedb.org/3/search/\(isSeries ? "tv" : "movie")")!
        let usesBearer = Self.isReadAccessToken(key)
        var qs: [URLQueryItem] = []
        if !usesBearer { qs.append(.init(name: "api_key", value: key)) }
        qs.append(contentsOf: [
            .init(name: "language", value: Self.language),
            .init(name: "include_adult", value: "false")
        ])
        if let year {
            qs.append(.init(name: isSeries ? "first_air_date_year" : "year", value: String(year)))
        }

        // 依次尝试变体，第一个有结果的就用
        var tmdbID: Int?
        for variant in variants {
            var tryQs = qs
            tryQs.append(.init(name: "query", value: variant))
            comps.queryItems = tryQs
            let searchData = try await get(comps.url!, bearer: usesBearer ? key : nil)
            guard let root = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { continue }
            // 逐个候选做相关性校验，避免把「瑞克和莫蒂」匹配成「超可动女孩」
            for candidate in results.prefix(6) {
                guard let id = candidate["id"] as? Int else { continue }
                let names = [candidate["name"], candidate["title"],
                             candidate["original_name"], candidate["original_title"]]
                    .compactMap { $0 as? String }
                let best = names.map { (name: $0, score: Self.matchScore(variant, $0)) }
                    .max { $0.score < $1.score }
                guard let best, best.score >= 0.55 else { continue }
                tmdbID = id
                AppLog.info("    TMDB 用「\(variant)」命中 id=\(id) name=\(best.name) 相似度=\(String(format: "%.2f", best.score))")
                break
            }
            if tmdbID != nil { break }
        }
        guard let tmdbID else { return nil }

        // 2) 详情 + credits
        let detailPath = "https://api.themoviedb.org/3/\(isSeries ? "tv" : "movie")/\(tmdbID)"
        var detailComps = URLComponents(string: detailPath)!
        var detailItems: [URLQueryItem] = []
        if !usesBearer { detailItems.append(.init(name: "api_key", value: key)) }
        detailItems.append(contentsOf: [
            .init(name: "language", value: Self.language),
            .init(name: "append_to_response", value: "credits")
        ])
        detailComps.queryItems = detailItems
        let detailData = try await get(detailComps.url!, bearer: usesBearer ? key : nil)
        guard let d = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] else {
            throw TMDBError.decode
        }

        var meta = MediaMetadata(itemID: itemID)
        meta.tmdbID = d["id"] as? Int
        meta.title = d["title"] as? String ?? d["name"] as? String
        meta.seriesTitle = d["name"] as? String ?? d["title"] as? String
        meta.originalTitle = d["original_title"] as? String ?? d["original_name"] as? String
        meta.overview = d["overview"] as? String
        meta.rating = (d["vote_average"] as? Double).map { ($0 * 10).rounded() / 10 }
        meta.voteCount = d["vote_count"] as? Int
        meta.posterPath = d["poster_path"] as? String
        meta.backdropPath = d["backdrop_path"] as? String
        meta.releaseDate = d["release_date"] as? String ?? d["first_air_date"] as? String
        meta.matchedName = meta.title

        if let genres = d["genres"] as? [[String: Any]] {
            meta.genres = genres.compactMap { $0["name"] as? String }
        }
        if let credits = d["credits"] as? [String: Any],
           let cast = credits["cast"] as? [[String: Any]] {
            meta.cast = cast.prefix(18).compactMap { c in
                guard let name = c["name"] as? String else { return nil }
                return CastMember(tmdbID: c["id"] as? Int,
                                  name: name,
                                  role: c["character"] as? String ?? "",
                                  profilePath: c["profile_path"] as? String)
            }
        }
        return meta
    }

    private func get(_ url: URL, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.decode }
        guard (200..<300).contains(http.statusCode) else { throw TMDBError.badResponse(http.statusCode) }
        return data
    }

    /// 查询词与候选标题的相似度（0…1）。中文场景下子串包含基本就够用。
    static func matchScore(_ query: String, _ candidate: String) -> Double {
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "·", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "：", with: "")
        }
        let q = norm(query), c = norm(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        if q == c { return 1 }
        if c.contains(q) || q.contains(c) {
            return Double(min(q.count, c.count)) / Double(max(q.count, c.count)) * 0.5 + 0.5
        }
        // 最长公共子序列比例
        let a = Array(q), b = Array(c)
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
            }
        }
        return Double(dp[a.count][b.count]) / Double(max(a.count, b.count))
    }

    /// 中英混排的目录名（`风骚律师.Better Call Saul.2160p`）要拆开分别试，
    /// 整串丢给 TMDB 是搜不到的。
    static func queryVariants(_ raw: String) -> [String] {
        let cleaned = searchableTitle(raw)
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " -_.·:："))
            guard !t.isEmpty, !out.contains(t) else { return }
            out.append(t)
        }
        add(cleaned)

        // 纯拉丁部分
        let latinRuns = cleaned.matches(of: /[A-Za-z0-9][A-Za-z0-9 '&:!,\-]*/).map { String($0.output) }
        let latin = latinRuns.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !latin.isEmpty, latin != cleaned { add(latin) }

        // 纯中文部分
        let cjkRuns = cleaned.matches(of: /[\p{Han}]+/).map { String($0.output) }
        let cjk = cjkRuns.joined(separator: " ")
        if !cjk.isEmpty, cjk != cleaned { add(cjk) }

        return out
    }

    /// 把「Better Call Saul S01」「帝国浩劫 1080p (2024)」这类标题收紧成可搜索的片名
    static func searchableTitle(_ raw: String) -> String {
        var s = raw
        // 季集标记：S01 / S01E02 / Season 1 / 第1季
        s = s.replacingOccurrences(of: "(?i)\\s*[.-]?\\s*S\\d{1,2}(E\\d{1,3})?(\\s*-\\s*S?\\d{1,2})?\\s*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\s*[.-]?\\s*Season\\s*\\d{1,2}\\s*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*第\\s*\\d{1,3}\\s*季\\s*$", with: "", options: .regularExpression)
        // 括号内容（年份、季范围、「满屏版」之类）
        s = s.replacingOccurrences(of: "\\s*[（(][^)）]*[)）]\\s*", with: " ", options: .regularExpression)
        // 分辨率/编码
        s = s.replacingOccurrences(of: "(?i)\\s*\\b(2160p|1080p|720p|480p|4k|uhd|hdr|web-?dl|webrip|bluray|blu-ray|x264|x265|h\\.?264|h\\.?265|hevc|10bit|8bit)\\b\\s*", with: " ", options: .regularExpression)
        // 去掉点分隔
        s = s.replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
    }
}

// MARK: - 轻量哈希

enum SHA256Lite {
    static func hash(_ s: String) -> String {
        // 用系统 CryptoKit 会引入依赖，这里用稳定 FNV-1a + 长度，够做文件名
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h) + "-\(s.count)"
    }
}
