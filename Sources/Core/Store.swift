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
        Keychain.delete(account: id.uuidString)
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
    @Published private(set) var sources: [MediaSourceConfig] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published private(set) var library: [MediaItem] = [] {
        didSet { contentRevision &+= 1 }
    }
    @Published private(set) var progress: [String: PlaybackRecord] = [:] {
        didSet { contentRevision &+= 1 }
    }
    private(set) var contentRevision: UInt64 = 0
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var artworkRevision = 0

    @Published var scanState: [UUID: ScanState] = [:]
    private var scanGenerations: [UUID: UUID] = [:]
    private var libraryGeneration = UUID()

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
        persistCredential(for: config)
        persist()
    }

    func updateSource(_ config: MediaSourceConfig) {
        guard let idx = sources.firstIndex(where: { $0.id == config.id }) else { return }
        invalidateScan(for: config.id)
        MetadataStore.shared.invalidate(items: library.filter { $0.sourceID == config.id })
        sources[idx] = config
        persistCredential(for: config)
        artworkRevision &+= 1
        LocalArtworkResolver.shared.invalidate()
        persist()
    }

    func removeSource(_ id: UUID) {
        invalidateScan(for: id)
        MetadataStore.shared.invalidate(items: library.filter { $0.sourceID == id })
        sources.removeAll { $0.id == id }
        library.removeAll { $0.sourceID == id }
        Credentials.delete(id)
        artworkRevision &+= 1
        LocalArtworkResolver.shared.invalidate()
        persist()
    }

    func source(for id: UUID) -> MediaSourceConfig? {
        sources.first { $0.id == id }
    }

    /// 只清索引与进度，不动磁盘文件
    func removeAllLibrary() {
        MetadataStore.shared.invalidate(items: library)
        libraryGeneration = UUID()
        scanGenerations.removeAll()
        library.removeAll()
        progress.removeAll()
        scanState.removeAll()
        artworkRevision &+= 1
        LocalArtworkResolver.shared.invalidate()
        persist()
    }

    private func persistCredential(for config: MediaSourceConfig) {
        if config.password.isEmpty {
            Credentials.delete(config.id)
        } else {
            Credentials.set(config.password, for: config.id)
        }
    }

    private func invalidateScan(for sourceID: UUID) {
        scanGenerations[sourceID] = UUID()
        scanState[sourceID] = nil
    }

    // MARK: 扫描

    func scan(_ config: MediaSourceConfig) async {
        let norm = config.normalized()
        guard !Task.isCancelled,
              source(for: config.id)?.normalized() == norm else { return }
        let generation = UUID()
        let librarySnapshot = libraryGeneration
        scanGenerations[config.id] = generation
        scanState[config.id] = ScanState(isScanning: true, found: 0, message: nil)
        defer {
            if ownsScan(norm, generation: generation, librarySnapshot: librarySnapshot),
               scanState[config.id]?.isScanning == true {
                scanState[config.id] = nil
            }
        }
        AppLog.info("开始扫描 \" \(norm.name)\" kind=\(norm.kind.rawValue) host=\(norm.host) port=\(norm.port) path=\(norm.basePath) https=\(norm.usesHTTPS) user=\(norm.username) pwdLen=\(norm.password.count)")
        do {
            let source = try MediaSourceFactory.make(norm)
            var collected: [MediaItem] = []
            if let catalog = source as? CatalogSource {
                collected = try await catalog.fetchCatalog()
                guard isCurrentScan(norm, generation: generation,
                                    librarySnapshot: librarySnapshot) else { return }
                scanState[config.id]?.found = collected.count
            } else {
                try await walk(source: source, config: norm, path: "", depth: 0,
                               generation: generation, librarySnapshot: librarySnapshot,
                               into: &collected) { n in
                    guard self.isCurrentScan(norm, generation: generation,
                                             librarySnapshot: librarySnapshot) else { return }
                    self.scanState[config.id]?.found = n
                }
            }
            guard isCurrentScan(norm, generation: generation,
                                librarySnapshot: librarySnapshot) else { return }

            var unique: [MediaItem] = []
            var seenPaths: Set<String> = []
            for item in collected where seenPaths.insert(item.path).inserted {
                unique.append(item)
            }
            // 合并：保留已有条目的 addedAt，避免"最近添加"乱跳
            var existing: [String: MediaItem] = [:]
            for item in library where item.sourceID == config.id {
                if existing[item.path] == nil { existing[item.path] = item }
            }
            let merged = unique.map { item -> MediaItem in
                var copy = item
                if let old = existing[item.path] { copy.addedAt = old.addedAt }
                return copy
            }
            MetadataStore.shared.invalidate(items: library.filter { $0.sourceID == config.id })
            library.removeAll { $0.sourceID == config.id }
            library.append(contentsOf: merged)
            library.sort { $0.addedAt > $1.addedAt }
            scanState[config.id] = ScanState(isScanning: false, found: merged.count, message: nil)
            artworkRevision &+= 1
            LocalArtworkResolver.shared.invalidate()   // 重新扫描后清封面路径缓存
            // 有 TMDB key 时，先刮「每部剧的第一集 + 电影」，保证剧名/海报齐全（也用于剧集归并）
            if !merged.isEmpty {
                let seriesHeads = LibraryGrouper.series(from: library).compactMap(\.posterItem)
                let movies = LibraryGrouper.movies(from: library).prefix(30)
                let targets = Array(seriesHeads) + Array(movies)
                Task { await MetadataStore.shared.scrapeAll(items: targets, in: self, limit: 80) }
            }
            AppLog.info("扫描完成 \" \(norm.name)\" 条目=\(merged.count)")
            persist()
        } catch {
            guard ownsScan(norm, generation: generation,
                           librarySnapshot: librarySnapshot) else { return }
            if Task.isCancelled || error is CancellationError {
                scanState[config.id] = nil
                return
            }
            scanState[config.id] = ScanState(isScanning: false, found: 0,
                                             message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            AppLog.error("扫描失败 \" \(norm.name)\"：\(error.logDescription)")
        }
    }

    private func ownsScan(_ config: MediaSourceConfig,
                          generation: UUID,
                          librarySnapshot: UUID) -> Bool {
        libraryGeneration == librarySnapshot
            && scanGenerations[config.id] == generation
            && source(for: config.id)?.normalized() == config
    }

    private func isCurrentScan(_ config: MediaSourceConfig,
                               generation: UUID,
                               librarySnapshot: UUID) -> Bool {
        !Task.isCancelled
            && ownsScan(config, generation: generation,
                        librarySnapshot: librarySnapshot)
    }

    private func walk(source: MediaSource,
                      config: MediaSourceConfig,
                      path: String,
                      depth: Int,
                      generation: UUID,
                      librarySnapshot: UUID,
                      into items: inout [MediaItem],
                      progress: (Int) -> Void) async throws {
        guard depth < 8 else { return }
        guard isCurrentScan(config, generation: generation,
                            librarySnapshot: librarySnapshot) else {
            throw CancellationError()
        }
        let entries = try await source.list(path: path)
        guard isCurrentScan(config, generation: generation,
                            librarySnapshot: librarySnapshot) else {
            throw CancellationError()
        }
        for entry in entries {
            guard isCurrentScan(config, generation: generation,
                                librarySnapshot: librarySnapshot) else {
                throw CancellationError()
            }
            if entry.isDirectory {
                if entry.name.lowercased() == ".lumen-cache" { continue }
                if MediaItemParser.isJunkFolder(entry.name) { continue }
                try await walk(source: source, config: config, path: entry.path,
                               depth: depth + 1, generation: generation,
                               librarySnapshot: librarySnapshot,
                               into: &items, progress: progress)
            } else if MediaFileType.isVideo(entry.name) {
                items.append(MediaItemParser.parse(entry: entry, sourceID: config.id))
                progress(items.count)
            }
        }
    }

    // MARK: 播放进度

    func rescanItem(_ item: MediaItem) async throws {
        try await scopedRescan(items: [item], series: false)
    }

    func rescanSeries(_ group: SeriesGroup) async throws {
        try await scopedRescan(items: group.items, series: true)
    }

    private func scopedRescan(items targets: [MediaItem], series: Bool) async throws {
        guard let first = targets.first, Set(targets.map(\.sourceID)).count == 1,
              let raw = source(for: first.sourceID) else { throw SourceError.invalidURL }
        let config = raw.normalized()
        guard !config.kind.isMediaServer && config.kind != .http else {
            throw SourceError.notImplemented("Scoped catalog rescan")
        }
        try Task.checkCancellation()
        let generation = UUID()
        let snapshot = libraryGeneration
        scanGenerations[config.id] = generation
        scanState[config.id] = ScanState(isScanning: true, found: 0, message: "Re-scanning selection")
        defer {
            if ownsScan(config, generation: generation, librarySnapshot: snapshot) {
                scanState[config.id] = nil
            }
        }
        let source = try MediaSourceFactory.make(config)
        let targetIDs = Set(targets.map(\.id))
        let targetPaths = Set(targets.map(\.path))
        let seriesNames = Set(targets.compactMap(\.seriesTitle).map { TMDBClient.searchableTitle($0).lowercased() })
        var roots = Set<String>()
        for item in targets {
            guard !item.path.hasPrefix("/"), !item.path.split(separator: "/").contains("..") else {
                throw SourceError.invalidURL
            }
            var directory = (item.path as NSString).deletingLastPathComponent
            if series, ArtworkMatcher.seasonNumber(fromDirectoryName: (directory as NSString).lastPathComponent) != nil {
                directory = (directory as NSString).deletingLastPathComponent
            }
            roots.insert(directory)
        }
        let selectedRoots = roots.filter { root in
            !roots.contains { other in !other.isEmpty && root != other && root.hasPrefix(other + "/") }
        }.sorted()
        var collected: [MediaItem] = []
        func collect(_ path: String, depth: Int) async throws {
            guard isCurrentScan(config, generation: generation, librarySnapshot: snapshot) else {
                throw CancellationError()
            }
            let entries = try await source.list(path: path)
            guard isCurrentScan(config, generation: generation, librarySnapshot: snapshot) else {
                throw CancellationError()
            }
            for entry in entries {
                // Reject malformed remote paths and only follow direct children inside this scope.
                guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains(".."),
                      (entry.path as NSString).deletingLastPathComponent == path else {
                    throw SourceError.invalidResponse("Out-of-scope rescan entry")
                }
                if entry.isDirectory {
                    guard series, !path.isEmpty, depth < 8,
                          entry.name.lowercased() != ".lumen-cache",
                          !MediaItemParser.isJunkFolder(entry.name) else { continue }
                    try await collect(entry.path, depth: depth + 1)
                } else if MediaFileType.isVideo(entry.name) {
                    let parsed = MediaItemParser.parse(entry: entry, sourceID: config.id)
                    if targetPaths.contains(entry.path)
                        || (series && parsed.seriesTitle.map { seriesNames.contains(TMDBClient.searchableTitle($0).lowercased()) } == true) {
                        collected.append(parsed)
                    }
                }
            }
        }
        for root in selectedRoots { try await collect(root, depth: 0) }
        guard isCurrentScan(config, generation: generation, librarySnapshot: snapshot) else {
            throw CancellationError()
        }
        guard !collected.isEmpty, series || collected.contains(where: { $0.path == first.path }) else {
            throw SourceError.invalidResponse("Selected media file was not found")
        }
        var oldByPath: [String: MediaItem] = [:]
        for item in library where item.sourceID == config.id { oldByPath[item.path] = item }
        var seen = Set<String>()
        let replacement = collected.filter { seen.insert($0.path).inserted }.map { item -> MediaItem in
            var copy = item
            if let old = oldByPath[item.path] { copy.addedAt = old.addedAt }
            return copy
        }
        let affected = library.filter { targetIDs.contains($0.id) || seen.contains($0.path) && $0.sourceID == config.id }
        MetadataStore.shared.invalidate(items: affected)
        library.removeAll { targetIDs.contains($0.id) || seen.contains($0.path) && $0.sourceID == config.id }
        library.append(contentsOf: replacement)
        library.sort { $0.addedAt == $1.addedAt ? $0.id < $1.id : $0.addedAt > $1.addedAt }
        artworkRevision &+= 1
        LocalArtworkResolver.shared.invalidate()
        persist()
    }

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

    func isSeriesFavorite(_ group: SeriesGroup) -> Bool {
        group.items.contains { favorites.contains($0.id) }
    }

    func toggleSeriesFavorite(_ group: SeriesGroup) {
        let itemIDs = Set(group.items.map(\.id))
        if !favorites.isDisjoint(with: itemIDs) {
            favorites.subtract(itemIDs)
        } else if let representative = itemIDs.min() {
            favorites.insert(representative)
        }
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
        let source = try MediaSourceFactory.make(config)
        let url = try await source.playURL(for: item.path)
        return PlaybackTarget(url: url, headers: source.playbackHeaders(),
                              resourceLease: source)
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
