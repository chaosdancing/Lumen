import Foundation
import Security
#if os(macOS)
import AppKit
#endif

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
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLog.error("Keychain 读取失败 status=\(status)")
        }
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

    private static let cacheLock = NSLock()
    private static var cache: [UUID: String] = [:]
    private static var loaded: Set<UUID> = []

    static func set(_ value: String, for id: UUID) -> Bool {
        let ok = Keychain.set(value, account: id.uuidString)
        if ok {
            cacheLock.lock()
            loaded.insert(id)
            if value.isEmpty { cache.removeValue(forKey: id) } else { cache[id] = value }
            cacheLock.unlock()
        }
        return ok
    }

    /// 同一个源在启动、扫描、播放时会多次读取凭据；这里缓存首次结果，
    /// 避免每次渲染/播放都触发一次钥匙串访问。
    static func get(_ id: UUID) -> String? {
        cacheLock.lock()
        if loaded.contains(id) {
            let cached = cache[id]
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var value = Keychain.get(account: id.uuidString)
        if value?.isEmpty != false {
            #if DEBUG
            value = devMap()[id.uuidString]
            #else
            value = nil
            #endif
        }
        if value?.isEmpty == true { value = nil }

        cacheLock.lock()
        loaded.insert(id)
        if let value { cache[id] = value } else { cache.removeValue(forKey: id) }
        cacheLock.unlock()
        return value
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
        cacheLock.lock()
        loaded.insert(id)
        cache.removeValue(forKey: id)
        cacheLock.unlock()
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
    @Published private(set) var library: [MediaItem] = [] {
        didSet { libraryVersion &+= 1 }
    }
    /// 播放中每 5 秒会更新一次进度。若每次都广播 objectWillChange，所有观察 AppStore 的页面
    /// （含播放器背后的首页）都会整页重算，所以这里手动控制广播：只有「状态变化」或距上次广播
    /// 超过 `progressPublishInterval` 才通知 UI；其余更新静默写入，下一次渲染时自然读到最新值。
    private(set) var progress: [String: PlaybackRecord] = [:] {
        willSet { if !suppressProgressPublish { objectWillChange.send() } }
    }
    private var suppressProgressPublish = false
    private var hasUnpublishedProgress = false
    private var lastProgressPublish = Date.distantPast
    private static let progressPublishInterval: TimeInterval = 30
    /// library 每次变化 +1，派生分组缓存以此判断是否失效
    private var libraryVersion: UInt64 = 0
    private struct GroupingCache {
        let libraryVersion: UInt64
        let metadataRevision: UInt64
        let titles: [String: String]
        let series: [SeriesGroup]
        let movies: [MediaItem]
    }
    private var groupingCache: GroupingCache?
    /// 持久化写盘放到串行队列，主线程只负责拷贝值；串行保证同一文件的写入顺序。
    private let ioQueue = DispatchQueue(label: "lumen.store.io", qos: .utility)
    private var progressWriteScheduled = false
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var iCloudProgressAvailable = false
    private var progressSync: ProgressCloudSync?
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
        #if os(macOS)
        // 写盘已改为后台串行队列；⌘Q 退出时不一定经过 scenePhase=.background，这里兜底刷盘。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushProgressSync() }
        }
        #endif
    }
    #if os(macOS)
    private var terminationObserver: NSObjectProtocol?
    #endif

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

    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: url, options: .atomic)
    }

    /// 全量落盘：源/库结构变化时才用。值类型快照在主线程拷贝，编码与写盘在 ioQueue。
    private func persist() {
        var sanitized = sources
        for i in sanitized.indices {
            sanitized[i].password = ""
        }
        let library = library
        let progress = progress
        let favorites = Array(favorites)
        ioQueue.async {
            Self.write(sanitized, to: StorePaths.sources)
            Self.write(library, to: StorePaths.library)
            Self.write(progress, to: StorePaths.progress)
            Self.write(favorites, to: StorePaths.favorites)
        }
    }

    /// 进度写入合并：同一个 runloop 周期内的多次更新只写一次，且不阻塞主线程。
    private func persistProgress() {
        guard !progressWriteScheduled else { return }
        progressWriteScheduled = true
        Task { @MainActor [weak self] in
            guard let self, self.progressWriteScheduled else { return }   // 已被 flush 提前写掉
            self.progressWriteScheduled = false
            let snapshot = self.progress
            self.ioQueue.async { Self.write(snapshot, to: StorePaths.progress) }
        }
    }

    /// 收藏只写 favorites.json，不再连带重写 676 KB 的 library.json。
    private func persistFavorites() {
        let snapshot = Array(favorites)
        ioQueue.async { Self.write(snapshot, to: StorePaths.favorites) }
    }

    /// 进入后台 / 关闭播放器时调用：把排队中的写盘同步刷完，避免被系统挂起时丢数据。
    private func flushPendingWrites() {
        if progressWriteScheduled {
            progressWriteScheduled = false
            let snapshot = progress
            ioQueue.async { Self.write(snapshot, to: StorePaths.progress) }
        }
        ioQueue.sync {}
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
        invalidateScan(for: normalized.id)
        MetadataStore.shared.invalidate(items: library.filter { $0.sourceID == normalized.id })
        if !normalized.password.isEmpty && !Credentials.set(normalized.password, for: normalized.id) { return false }
        if normalized.password.isEmpty { Credentials.delete(normalized.id) }
        sources[idx] = normalized
        artworkRevision &+= 1
        LocalArtworkResolver.shared.invalidate()
        persist()
        return true
    }

    func removeSource(_ id: UUID) {
        invalidateScan(for: id)
        MetadataStore.shared.invalidate(items: library.filter { $0.sourceID == id })
        sources.removeAll { $0.id == id }
        let removedIDs = Set(library.filter { $0.sourceID == id }.map(\.id))
        library.removeAll { $0.sourceID == id }
        progress = progress.filter { !removedIDs.contains($0.key) }
        favorites.subtract(removedIDs)
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
        progressSync?.clearAll()
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

    private func invalidateScan(for sourceID: UUID) {
        scanGenerations[sourceID] = UUID()
        scanState[sourceID] = nil
    }

    // MARK: 扫描

    func scan(_ config: MediaSourceConfig) async {
        guard scanState[config.id]?.isScanning != true else { return }
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
            if let records = progressSync?.currentRecords() { applySyncedProgress(records) }
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
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0 else { return }
        let record = PlaybackRecord(itemID: itemID, position: position,
                                    duration: duration, updatedAt: Date())
        let old = progress[itemID]
        // 只有「继续观看 / 已看完」这类列表归属发生变化才需要立即刷新 UI；
        // 单纯的位置推进最多 30 秒广播一次，避免播放时首页每 5 秒整页重算。
        let stateChanged = old == nil
            || old?.isInProgress != record.isInProgress
            || old?.isFinished != record.isFinished
        let now = Date()
        if stateChanged || now.timeIntervalSince(lastProgressPublish) >= Self.progressPublishInterval {
            progress[itemID] = record
            lastProgressPublish = now
            hasUnpublishedProgress = false
        } else {
            suppressProgressPublish = true
            progress[itemID] = record
            suppressProgressPublish = false
            hasUnpublishedProgress = true
        }
        persistProgress()
        if let item = item(withID: itemID) {
            progressSync?.record(record, for: item)
        }
    }

    /// 把静默写入的进度补发一次刷新（关闭播放器、进入后台时调用）。
    private func publishPendingProgress() {
        guard hasUnpublishedProgress else { return }
        hasUnpublishedProgress = false
        lastProgressPublish = Date()
        objectWillChange.send()
    }

    func record(for itemID: String) -> PlaybackRecord? { progress[itemID] }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        persistFavorites()
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
        persistFavorites()
    }

    func clearProgress(itemID: String) {
        progress[itemID] = nil
        persistProgress()
        if let item = item(withID: itemID) {
            progressSync?.clear(item)
        }
    }

    func flushProgressSync() {
        publishPendingProgress()
        flushPendingWrites()
        progressSync?.flush(force: true)
        iCloudProgressAvailable = progressSync?.isAvailable ?? false
    }

    // MARK: 索引

    /// id → 下标、iCloud 进度 key → itemIDs。按 libraryVersion 惰性重建，
    /// 避免每 5 秒一次的 `library.first(where:)` 和每次 iCloud 推送都对全库重新做正则 + SHA256。
    private struct LibraryIndex {
        let version: UInt64
        let position: [String: Int]
        let itemsByProgressKey: [String: [String]]
    }
    private var libraryIndex: LibraryIndex?
    /// ProgressIdentity.key 只依赖条目自身的字段，按 id 记忆化，扫描替换后的旧条目通过
    /// 「标识字段」比较判断是否仍可复用。
    private var progressKeyMemo: [String: (fingerprint: String, key: String)] = [:]

    private func currentIndex() -> LibraryIndex {
        if let index = libraryIndex, index.version == libraryVersion { return index }
        var position: [String: Int] = [:]
        position.reserveCapacity(library.count)
        var byKey: [String: [String]] = [:]
        var memo: [String: (fingerprint: String, key: String)] = [:]
        memo.reserveCapacity(library.count)
        for (i, item) in library.enumerated() {
            if position[item.id] == nil { position[item.id] = i }
            let fingerprint = ProgressIdentity.fingerprint(for: item)
            let key: String
            if let cached = progressKeyMemo[item.id], cached.fingerprint == fingerprint {
                key = cached.key
            } else {
                key = ProgressIdentity.key(for: item)
            }
            memo[item.id] = (fingerprint, key)
            byKey[key, default: []].append(item.id)
        }
        progressKeyMemo = memo
        let index = LibraryIndex(version: libraryVersion, position: position, itemsByProgressKey: byKey)
        libraryIndex = index
        return index
    }

    func item(withID id: String) -> MediaItem? {
        guard let i = currentIndex().position[id], library.indices.contains(i),
              library[i].id == id else { return library.first { $0.id == id } }
        return library[i]
    }

    private func applySyncedProgress(_ records: [String: CloudProgress]) {
        guard !records.isEmpty else { return }
        let index = currentIndex()
        // 在副本上合并，最后一次性赋值，只触发一次 UI 刷新。
        var next = progress
        var changed = false
        for (key, incoming) in records {
            guard let ids = index.itemsByProgressKey[key] else { continue }
            for id in ids {
                let localDate = next[id]?.updatedAt ?? .distantPast
                guard incoming.updatedAt > localDate else { continue }
                if incoming.deleted {
                    if next.removeValue(forKey: id) != nil { changed = true }
                } else if incoming.duration > 0, incoming.position.isFinite,
                          incoming.duration.isFinite {
                    next[id] = PlaybackRecord(itemID: id, position: incoming.position,
                                              duration: incoming.duration,
                                              updatedAt: incoming.updatedAt)
                    changed = true
                }
            }
        }
        guard changed else { return }
        progress = next
        hasUnpublishedProgress = false
        lastProgressPublish = Date()
        persistProgress()
    }

    // MARK: 派生视图

    /// 剧集分组涉及多条正则清洗 + 排序，1000+ 条目时单次几十毫秒。结果按
    /// (libraryVersion, 刮削剧名) 缓存，进度/收藏变化不再触发重算。
    private func grouping() -> GroupingCache {
        let meta = MetadataStore.shared
        if let cache = groupingCache, cache.libraryVersion == libraryVersion,
           cache.metadataRevision == meta.revision {
            return cache
        }
        var titles: [String: String] = [:]
        for (id, m) in meta.items {
            if let t = m.seriesTitle, !t.isEmpty { titles[id] = t }
        }
        // 元数据 revision 变化但剧名没变（例如只补了海报/简介）时直接复用分组结果。
        if let cache = groupingCache, cache.libraryVersion == libraryVersion, cache.titles == titles {
            let refreshed = GroupingCache(libraryVersion: libraryVersion, metadataRevision: meta.revision,
                                          titles: titles, series: cache.series, movies: cache.movies)
            groupingCache = refreshed
            return refreshed
        }
        let cache = GroupingCache(libraryVersion: libraryVersion,
                                  metadataRevision: meta.revision,
                                  titles: titles,
                                  series: LibraryGrouper.series(from: library, scrapedTitles: titles),
                                  movies: LibraryGrouper.movies(from: library))
        groupingCache = cache
        return cache
    }

    var seriesGroups: [SeriesGroup] { grouping().series }
    var movieItems: [MediaItem] { grouping().movies }

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
              let remoteID = item.remoteID else { return nil }
        return MediaServerSource.posterURL(config: config, id: remoteID)
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
