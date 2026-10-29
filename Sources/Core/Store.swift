import Foundation
import Security

// MARK: - Keychain（密码不进 JSON）

enum Keychain {
    private static let service = "com.example.lumen.credentials"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess { AppLog.error("Keychain 读取失败 status=\(status)") }
        guard status == errSecSuccess,
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
/// 旧版 DEBUG 明文凭据在首次读取后迁移到钥匙串。
enum Credentials {
    private static var devFileURL: URL { StorePaths.root.appendingPathComponent("credentials.dev.json") }

    private static func devMap() -> [String: String] {
        guard let data = try? Data(contentsOf: devFileURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func set(_ value: String, for id: UUID) -> Bool {
        Keychain.set(value, account: id.uuidString)
    }

    static func get(_ id: UUID) -> String? {
        let v = Keychain.get(account: id.uuidString)
        if v?.isEmpty == false { return v }
        #if DEBUG
        return devMap()[id.uuidString]
        #else
        return nil
        #endif
    }

    static func migrateLegacy() {
        let map = devMap()
        guard !map.isEmpty else { return }
        // 已保存的钥匙串凭据优先；旧开发缓存不能在重启时覆盖新密码。
        let migrated = map.allSatisfy { account, legacyValue in
            if let existing = Keychain.get(account: account), !existing.isEmpty { return true }
            return Keychain.set(legacyValue, account: account)
        }
        AppLog.info("旧凭据迁移 count=\(map.count) success=\(migrated)")
        if migrated { try? FileManager.default.removeItem(at: devFileURL) }
    }

    static func delete(_ id: UUID) {
        Keychain.delete(account: id.uuidString)
        #if DEBUG
        var map = devMap()
        if map.removeValue(forKey: id.uuidString) != nil {
            if map.isEmpty { try? FileManager.default.removeItem(at: devFileURL) }
            else if let data = try? JSONEncoder().encode(map) {
                try? data.write(to: devFileURL, options: .atomic)
            }
        }
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
    @Published private(set) var iCloudProgressAvailable = false
    private var progressSync: ProgressCloudSync?

    @Published var scanState: [UUID: ScanState] = [:]

    struct ScanState: Equatable {
        var isScanning = false
        var found = 0
        var message: String?
    }

    init() {
        load()
        let sync = ProgressCloudSync()
        progressSync = sync
        sync.start(library: library, progress: progress) { [weak self] records in
            self?.applySyncedProgress(records)
        }
        iCloudProgressAvailable = sync.isAvailable
        // 旧版详细 mpv 日志可能包含 WebDAV Authorization 请求头。
        try? FileManager.default.removeItem(at: StorePaths.root.appendingPathComponent("mpv.log"))
        // 诊断探针不依赖窗口出现，放在这里保证一定执行
        Task { @MainActor in await DebugProbes.run(store: self) }
    }

    // MARK: 读写

    private func load() {
        #if DEBUG
        // 用户明确要求重置时，由设备容器内的一次性标记指定唯一文件源。
        let resetFlag = StorePaths.root.appendingPathComponent("reset-source-credential.flag")
        if let raw = try? String(contentsOf: resetFlag, encoding: .utf8),
           let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let data = try? Data(contentsOf: StorePaths.sources),
           let configs = try? JSONDecoder().decode([MediaSourceConfig].self, from: data),
           configs.contains(where: { $0.id == id }) {
            Credentials.delete(id)
            let cleared = Credentials.get(id) == nil
            AppLog.info("凭据重置 source=\(id) cleared=\(cleared)")
            if cleared { try? FileManager.default.removeItem(at: resetFlag) }
        }
        #endif
        // 先迁移再读取，保证首次启动即使用钥匙串中的最新凭据。
        Credentials.migrateLegacy()
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
            sanitized[i].password = ""
        }
        try? encoder.encode(sanitized).write(to: StorePaths.sources, options: .atomic)
        try? encoder.encode(library).write(to: StorePaths.library, options: .atomic)
        try? encoder.encode(progress).write(to: StorePaths.progress, options: .atomic)
        try? encoder.encode(Array(favorites)).write(to: StorePaths.favorites, options: .atomic)
    }

    private func persistProgress() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(progress).write(to: StorePaths.progress, options: .atomic)
    }

    // MARK: 源管理

    @discardableResult
    func addSource(_ config: MediaSourceConfig) -> Bool {
        let normalized = config.normalized()
        if !normalized.password.isEmpty && !Credentials.set(normalized.password, for: normalized.id) { return false }
        sources.append(normalized)
        persist()
        return true
    }

    @discardableResult
    func updateSource(_ config: MediaSourceConfig) -> Bool {
        guard let idx = sources.firstIndex(where: { $0.id == config.id }) else { return false }
        let normalized = config.normalized()
        if !normalized.password.isEmpty && !Credentials.set(normalized.password, for: normalized.id) { return false }
        if normalized.password.isEmpty { Credentials.delete(normalized.id) }
        sources[idx] = normalized
        persist()
        return true
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        let removedIDs = Set(library.filter { $0.sourceID == id }.map(\.id))
        library.removeAll { $0.sourceID == id }
        progress = progress.filter { !removedIDs.contains($0.key) }
        favorites.subtract(removedIDs)
        Credentials.delete(id)
        persist()
    }

    func source(for id: UUID) -> MediaSourceConfig? {
        sources.first { $0.id == id }
    }

    /// 只清索引与进度，不动磁盘文件
    func removeAllLibrary() {
        progressSync?.clearAll()
        library.removeAll()
        progress.removeAll()
        scanState.removeAll()
        persist()
    }

    // MARK: 扫描

    func scan(_ config: MediaSourceConfig) async {
        guard scanState[config.id]?.isScanning != true else { return }
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
            guard sources.contains(where: { $0.id == config.id }) else { return }
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
            if let records = progressSync?.currentRecords() { applySyncedProgress(records) }
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
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0 else { return }
        let record = PlaybackRecord(itemID: itemID, position: position,
                                    duration: duration, updatedAt: Date())
        progress[itemID] = record
        persistProgress()
        if let item = library.first(where: { $0.id == itemID }) {
            progressSync?.record(record, for: item)
        }
    }

    func record(for itemID: String) -> PlaybackRecord? { progress[itemID] }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        persist()
    }

    func clearProgress(itemID: String) {
        progress[itemID] = nil
        persistProgress()
        if let item = library.first(where: { $0.id == itemID }) {
            progressSync?.clear(item)
        }
    }

    func flushProgressSync() {
        progressSync?.flush(force: true)
        iCloudProgressAvailable = progressSync?.isAvailable ?? false
    }

    private func applySyncedProgress(_ records: [String: CloudProgress]) {
        var changed = false
        for item in library {
            guard let incoming = records[ProgressIdentity.key(for: item)] else { continue }
            let localDate = progress[item.id]?.updatedAt ?? .distantPast
            guard incoming.updatedAt > localDate else { continue }
            if incoming.deleted {
                if progress.removeValue(forKey: item.id) != nil { changed = true }
            } else if incoming.duration > 0, incoming.position.isFinite,
                      incoming.duration.isFinite {
                progress[item.id] = PlaybackRecord(itemID: item.id, position: incoming.position,
                                                    duration: incoming.duration,
                                                    updatedAt: incoming.updatedAt)
                changed = true
            }
        }
        if changed { persistProgress() }
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
                guard let r = progress[item.id], r.isInProgress else { return nil }
                return (item, r)
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .map(\.0)
    }

    var recentlyAdded: [MediaItem] {
        Array(library.sorted { $0.addedAt > $1.addedAt }.prefix(60))
    }

    func playbackTarget(for item: MediaItem) async throws -> PlaybackTarget {
        guard let config = source(for: item.sourceID) else { throw SourceError.invalidURL }
        let saved = Credentials.get(config.id)
        AppLog.info("播放凭据 source=\(config.id) memoryPresent=\(!config.password.isEmpty) savedPresent=\(saved?.isEmpty == false) matches=\(saved == config.password)")
        let source = try MediaSourceFactory.make(config)
        let url = try await source.playURL(for: item.path)
        return PlaybackTarget(url: url,
                              headers: source.playbackHeaders(),
                              credentials: source.playbackCredentials(),
                              accessLease: source)
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
