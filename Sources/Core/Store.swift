import Foundation
import Security

// MARK: - Keychain（密码不进 JSON）

enum Keychain {
    private static let service = "com.example.lumen.credentials"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 凭据
/// 正式环境只用钥匙串。DEBUG 构建额外写一份本地缓存 ——
/// ad-hoc 签名的应用每次重新编译都会丢失钥匙串授权，开发期不这么做每改一次代码就得重输密码。
enum Credentials {
    private static var devFileURL: URL { StorePaths.root.appendingPathComponent("credentials.dev.json") }

    private static func devMap() -> [String: String] {
        guard let data = try? Data(contentsOf: devFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func set(_ value: String, for id: UUID) {
        #if !DEBUG
        Keychain.set(value, account: id.uuidString)
        #endif
        #if DEBUG
        var map = devMap()
        map[id.uuidString] = value
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: devFileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devFileURL.path)
        }
        #endif
    }

    static func get(_ id: UUID) -> String? {
        #if DEBUG
        // 开发期只读本地文件：ad-hoc 签名每次重编都会变，读钥匙串会弹授权框并阻塞主线程
        return devMap()[id.uuidString]
        #else
        let v = Keychain.get(account: id.uuidString)
        return (v?.isEmpty == false) ? v : nil
        #endif
    }

    static func delete(_ id: UUID) {
        Credentials.delete(id)
        #if DEBUG
        var map = devMap()
        map.removeValue(forKey: id.uuidString)
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: devFileURL, options: .atomic) }
        #endif
    }
}

// MARK: - 磁盘布局

enum StorePaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var sources: URL { root.appendingPathComponent("sources.json") }
    static var library: URL { root.appendingPathComponent("library.json") }
    static var progress: URL { root.appendingPathComponent("progress.json") }
    static var favorites: URL { root.appendingPathComponent("favorites.json") }
}

// MARK: - 应用状态

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var sources: [MediaSourceConfig] = []
    @Published private(set) var library: [MediaItem] = []
    @Published private(set) var progress: [String: PlaybackRecord] = [:]
    @Published private(set) var favorites: Set<String> = []

    @Published var scanState: [UUID: ScanState] = [:]

    struct ScanState: Equatable {
        var isScanning = false
        var found = 0
        var message: String?
    }

    init() {
        load()
        // 诊断探针不依赖窗口出现，放在这里保证一定执行
        Task { @MainActor in await DebugProbes.run(store: self) }
    }

    // MARK: 读写

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: StorePaths.sources),
           let list = try? decoder.decode([MediaSourceConfig].self, from: data) {
            sources = list.map { cfg in
                var copy = cfg
                copy.password = Credentials.get(cfg.id) ?? ""
                return copy
            }
        }
        if let data = try? Data(contentsOf: StorePaths.library),
           let list = try? decoder.decode([MediaItem].self, from: data) {
            library = list
        }
        if let data = try? Data(contentsOf: StorePaths.progress),
           let map = try? decoder.decode([String: PlaybackRecord].self, from: data) {
            progress = map
        }
        if let data = try? Data(contentsOf: StorePaths.favorites),
           let list = try? decoder.decode([String].self, from: data) {
            favorites = Set(list)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var sanitized = sources
        for i in sanitized.indices {
            let pwd = sanitized[i].password
            if !pwd.isEmpty { Credentials.set(pwd, for: sanitized[i].id) }
            sanitized[i].password = ""
        }
        try? encoder.encode(sanitized).write(to: StorePaths.sources, options: .atomic)
        try? encoder.encode(library).write(to: StorePaths.library, options: .atomic)
        try? encoder.encode(progress).write(to: StorePaths.progress, options: .atomic)
        try? encoder.encode(Array(favorites)).write(to: StorePaths.favorites, options: .atomic)
    }

    // MARK: 源管理

    func addSource(_ config: MediaSourceConfig) {
        sources.append(config)
        persist()
    }

    func updateSource(_ config: MediaSourceConfig) {
        guard let idx = sources.firstIndex(where: { $0.id == config.id }) else { return }
        sources[idx] = config
        persist()
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        library.removeAll { $0.sourceID == id }
        Credentials.delete(id)
        persist()
    }

    func source(for id: UUID) -> MediaSourceConfig? {
        sources.first { $0.id == id }
    }

    /// 只清索引与进度，不动磁盘文件
    func removeAllLibrary() {
        library.removeAll()
        progress.removeAll()
        scanState.removeAll()
        persist()
    }

    // MARK: 扫描

    func scan(_ config: MediaSourceConfig) async {
        scanState[config.id] = ScanState(isScanning: true, found: 0, message: nil)
        let norm = config.normalized()
        AppLog.info("开始扫描 \" \(norm.name)\" kind=\(norm.kind.rawValue) host=\(norm.host) port=\(norm.port) path=\(norm.basePath) https=\(norm.usesHTTPS) user=\(norm.username) pwdLen=\(norm.password.count)")
        do {
            let source = try MediaSourceFactory.make(config)
            var collected: [MediaItem] = []
            if let catalog = source as? CatalogSource {
                collected = try await catalog.fetchCatalog()
                self.scanState[config.id]?.found = collected.count
            } else {
                try await walk(source: source, config: config, path: "", depth: 0, into: &collected) { n in
                    self.scanState[config.id]?.found = n
                }
            }
            // 合并：保留已有条目的 addedAt，避免"最近添加"乱跳
            let existing = Dictionary(uniqueKeysWithValues: library.filter { $0.sourceID == config.id }.map { ($0.path, $0) })
            let merged = collected.map { item -> MediaItem in
                var copy = item
                if let old = existing[item.path] { copy.addedAt = old.addedAt }
                return copy
            }
            library.removeAll { $0.sourceID == config.id }
            library.append(contentsOf: merged)
            library.sort { $0.addedAt > $1.addedAt }
            scanState[config.id] = ScanState(isScanning: false, found: merged.count, message: nil)
            LocalArtworkResolver.shared.invalidate()   // 重新扫描后清封面路径缓存
            // 有 TMDB key 时，先刮「每部剧的第一集 + 电影」，保证剧名/海报齐全（也用于剧集归并）
            if TMDBClient.apiKey != nil {
                let seriesHeads = LibraryGrouper.series(from: library).compactMap(\.posterItem)
                let movies = LibraryGrouper.movies(from: library).prefix(30)
                let targets = Array(seriesHeads) + Array(movies)
                Task { await MetadataStore.shared.scrapeAll(items: targets, in: self, limit: 80) }
            }
            AppLog.info("扫描完成 \" \(norm.name)\" 条目=\(merged.count)")
            persist()
        } catch {
            scanState[config.id] = ScanState(isScanning: false, found: 0,
                                             message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            AppLog.error("扫描失败 \" \(norm.name)\"：\(error.logDescription)")
        }
    }

    private func walk(source: MediaSource,
                      config: MediaSourceConfig,
                      path: String,
                      depth: Int,
                      into items: inout [MediaItem],
                      progress: (Int) -> Void) async throws {
        guard depth < 8 else { return }
        let entries = try await source.list(path: path)
        for entry in entries {
            if entry.isDirectory {
                if MediaItemParser.isJunkFolder(entry.name) { continue }
                try await walk(source: source, config: config, path: entry.path,
                               depth: depth + 1, into: &items, progress: progress)
            } else if MediaFileType.isVideo(entry.name) {
                items.append(MediaItemParser.parse(entry: entry, sourceID: config.id))
                progress(items.count)
            }
        }
    }

    // MARK: 播放进度

    func record(itemID: String, position: Double, duration: Double) {
        guard duration > 0 else { return }
        progress[itemID] = PlaybackRecord(itemID: itemID, position: position,
                                          duration: duration, updatedAt: Date())
        persist()
    }

    func record(for itemID: String) -> PlaybackRecord? { progress[itemID] }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        persist()
    }

    func clearProgress(itemID: String) {
        progress[itemID] = nil
        persist()
    }

    // MARK: 派生视图

    var seriesGroups: [SeriesGroup] {
        let meta = MetadataStore.shared.items
        var titles: [String: String] = [:]
        for (id, m) in meta {
            if let t = m.seriesTitle, !t.isEmpty { titles[id] = t }
        }
        return LibraryGrouper.series(from: library, scrapedTitles: titles)
    }
    var movieItems: [MediaItem] { LibraryGrouper.movies(from: library) }

    var continueWatching: [MediaItem] {
        library
            .compactMap { item -> (MediaItem, PlaybackRecord)? in
                guard let r = progress[item.id], !r.isFinished, r.progress > 0.02 else { return nil }
                return (item, r)
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .prefix(12)
            .map(\.0)
    }

    var recentlyAdded: [MediaItem] {
        Array(library.sorted { $0.addedAt > $1.addedAt }.prefix(60))
    }

    func playbackTarget(for item: MediaItem) async throws -> PlaybackTarget {
        guard let config = source(for: item.sourceID) else { throw SourceError.invalidURL }
        if config.kind == .http, let url = URL(string: config.directURL) {
            return PlaybackTarget(url: url, headers: [:])
        }
        let source = try MediaSourceFactory.make(config)
        let url = try await source.playURL(for: item.path)
        return PlaybackTarget(url: url, headers: source.playbackHeaders())
    }

    /// 从某个源里读文件字节（封面/字幕共用）
    func data(for item: MediaItem, path: String) async throws -> Data {
        guard let config = source(for: item.sourceID) else { throw SourceError.invalidURL }
        let src = try MediaSourceFactory.make(config)
        return try await src.data(for: path)
    }

    // MARK: 海报

    func posterURL(for item: MediaItem) -> URL? {
        guard let config = source(for: item.sourceID), config.kind.isMediaServer,
              let remoteID = item.remoteID,
              let server = try? MediaServerSource(config: config) else { return nil }
        return server.posterURL(for: remoteID)
    }

    // MARK: 字幕

    /// 同目录、同主文件名的字幕文件（.srt/.ass/.ssa/.vtt）
    func subtitleCandidates(for item: MediaItem) async -> [String] {
        guard let config = source(for: item.sourceID), !config.kind.isMediaServer,
              let src = try? MediaSourceFactory.make(config) else { return [] }
        let dir = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let entries = try? await src.list(path: dir) else { return [] }
        return entries
            .filter { !$0.isDirectory }
            .filter { ($0.name as NSString).deletingPathExtension == stem }
            .filter { SubtitleParser.format(for: $0.name) != nil }
            .map(\.path)
            .sorted()
    }

    func subtitleCues(for item: MediaItem, path: String) async -> [SubtitleCue] {
        guard let config = source(for: item.sourceID),
              let src = try? MediaSourceFactory.make(config),
              let data = try? await src.data(for: path) else { return [] }
        return SubtitleParser.parse(data: data, path: path)
    }
}
