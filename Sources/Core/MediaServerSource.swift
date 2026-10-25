import Foundation

/// 媒体服务器（Emby / Jellyfin）不是"目录树"，而是"条目库"。
/// 所以单开一个能力协议，扫描时走 catalog 而不是递归 walk。
protocol CatalogSource: MediaSource {
    func fetchCatalog() async throws -> [MediaItem]
}

// MARK: - Emby / Jellyfin

/// 两者 API 几乎一致（Jellyfin 是 Emby 的 fork），差别只在鉴权头与个别字段。
/// 用 API Key 鉴权：把 Key 填在"密码"字段里（存钥匙串）。
final class MediaServerSource: CatalogSource, @unchecked Sendable {
    let config: MediaSourceConfig
    private let base: URL
    private let session: URLSession

    init(config: MediaSourceConfig) throws {
        self.config = config
        let scheme = config.usesHTTPS ? "https" : "http"
        let port = config.port == 0 ? "" : ":\(config.port)"
        let path = config.basePath == "/" ? "" : config.basePath
        guard let url = URL(string: "\(scheme)://\(config.host)\(port)\(path)") else {
            throw SourceError.invalidURL
        }
        self.base = url
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg,
                                  delegate: LocalNetworkTrustDelegate.shared,
                                  delegateQueue: nil)
    }

    private var apiKey: String { config.password }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "X-Emby-Token")
        req.setValue("MediaBrowser Token=\"\(apiKey)\", Client=\"Lumen\", Device=\"Mac\", DeviceId=\"lumen\", Version=\"0.1.0\"",
                     forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: 目录接口（不用，但协议要求）

    func list(path: String) async throws -> [RemoteEntry] { [] }

    func data(for path: String) async throws -> Data {
        throw SourceError.notImplemented("媒体服务器字幕")
    }

    // MARK: 条目库

    func fetchCatalog() async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "Fields", value: "Path,ProductionYear,ParentIndexNumber,IndexNumber,SeriesName,RunTimeTicks,ImageTags,MediaSources"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "Limit", value: "5000")
        ]
        let (data, response) = try await session.data(for: request("Items", query: query))
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse(0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw SourceError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.badResponse(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]] else {
            throw SourceError.badResponse(http.statusCode)
        }

        return items.compactMap { dict -> MediaItem? in
            guard let id = dict["Id"] as? String else { return nil }
            let name = dict["Name"] as? String ?? "未命名"
            let series = dict["SeriesName"] as? String
            let season = dict["ParentIndexNumber"] as? Int
            let episode = dict["IndexNumber"] as? Int
            let year = dict["ProductionYear"] as? Int
            let ticks = dict["RunTimeTicks"] as? Double
            let isEpisode = series != nil || episode != nil

            var title = name
            if isEpisode, let s = season, let e = episode {
                title = String(format: "S%02dE%02d", s, e)
            }
            return MediaItem(
                id: "\(config.id.uuidString)#\(id)",
                sourceID: config.id,
                path: id,                     // 服务器条目用 ID 当路径
                fileName: name,
                title: title,
                seriesTitle: isEpisode ? (series ?? name) : nil,
                season: season,
                episode: episode,
                year: year,
                size: ticks.map { Int64($0 / 10_000_000) },   // 用时长占位，UI 只用来判断非空
                addedAt: Date(),
                remoteID: id
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: 取流

    func playURL(for path: String) async throws -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("Videos/\(path)/stream"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = comps.url else { throw SourceError.invalidURL }
        return url
    }

    /// 海报
    func posterURL(for id: String, maxHeight: Int = 450) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(id)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        return comps.url
    }
}
