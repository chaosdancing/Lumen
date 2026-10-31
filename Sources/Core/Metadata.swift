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
    var cacheVersion: Int?
    var preferNFO: Bool?
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
    var certification: String?
    var certificationRegion: String?
    var mediaType: String?
    var runtimeMinutes: Int?
    var fieldSources: [String: String]?
    var metadataLanguage: String?
    var sourceFingerprint: String?
    var artworkRefreshID: String?
    var seriesCacheKey: String?
    var matchedName: String?
    var source: String = "tmdb"  // tmdb | nfo
    var updatedAt: Date = Date()
}

// MARK: - 元数据仓库（刮削 + 缓存）

@MainActor
final class MetadataStore: ObservableObject {
    static let shared = MetadataStore()
    private static let cacheVersion = 3

    @Published private(set) var items: [String: MediaMetadata] = [:]
    /// Published after item and series caches are consistent, so classifications see completed data.
    @Published private(set) var revision: UInt64 = 0
    /// 剧集级缓存：同一部剧的多个 episode 只查一次 TMDB
    private var seriesCache: [String: MediaMetadata] = [:]
    private struct SeriesRequest {
        let id = UUID()
        let task: Task<MediaMetadata?, Error>
    }
    private var seriesRequests: [String: SeriesRequest] = [:]
    private var seriesMisses: Set<String> = []
    private var remoteCache: [String: MediaMetadata] = [:]
    private var diskLookups: [String: MediaMetadata] = [:]
    private var diskMisses: Set<String> = []
    private var fingerprints: [UUID: (config: MediaSourceConfig, value: String)] = [:]
    @Published private(set) var inFlight: Set<String> = []
    @Published var lastError: String?
    @Published private(set) var loadState: [String: MetadataLoadState] = [:]
    private var requests: [String: InFlightRequest] = [:]
    private var interimItems: Set<String> = []
    private let client: TMDBClient
    private weak var sourceStore: AppStore?
    private var diskSources: [UUID: MediaSourceConfig] = [:]

    private struct RequestContext: Equatable {
        let id: UUID
        let preferNFO: Bool
        let sourceConfig: MediaSourceConfig?
        let artworkRevision: Int
        let language: String
        let force: Bool

        func hasSameInputs(preferNFO: Bool, sourceConfig: MediaSourceConfig?,
                           artworkRevision: Int) -> Bool {
            self.preferNFO == preferNFO
                && self.sourceConfig == sourceConfig
                && self.artworkRevision == artworkRevision
                && self.language == TMDBClient.language
        }
    }

    private struct InFlightRequest {
        let context: RequestContext
        let task: Task<Void, Never>
        var waiterCount: Int
    }

    private var cacheDir: URL {
        let dir = StorePaths.root.appendingPathComponent("Metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(client: TMDBClient = .shared) {
        self.client = client
        if let data = try? Data(contentsOf: StorePaths.root.appendingPathComponent("sources.json")),
           let configs = try? JSONDecoder().decode([MediaSourceConfig].self, from: data) {
            for config in configs { diskSources[config.id] = config }
        }
        loadAllFromDisk()
    }

    // MARK: 读取

    private func sourceConfig(for sourceID: UUID) -> MediaSourceConfig? {
        if let sourceStore { return sourceStore.source(for: sourceID) }
        return diskSources[sourceID]
    }

    private func fingerprint(_ config: MediaSourceConfig) -> String {
        if let cached = fingerprints[config.id], cached.config == config { return cached.value }
        let value = MetadataCache.sourceFingerprint(config)
        fingerprints[config.id] = (config, value)
        return value
    }

    private func cachedEnvelope(identity: String, config: MediaSourceConfig) -> MediaMetadata? {
        if let cached = diskLookups[identity] { return cached }
        if diskMisses.contains(identity) { return nil }
        if let cached = MetadataCache.local(identity: identity, sourceConfig: config) {
            diskLookups[identity] = cached
            return cached
        }
        diskMisses.insert(identity)
        return nil
    }

    func metadata(for itemID: String) -> MediaMetadata? {
        guard let sourceID = UUID(uuidString: String(itemID.split(separator: "#").first ?? "")),
              let config = sourceConfig(for: sourceID), let meta = items[itemID],
              meta.sourceFingerprint == fingerprint(config) else { return nil }
        return meta
    }

    func cachedSeriesMetadata(for item: MediaItem) -> MediaMetadata? {
        guard let key = Self.seriesKey(for: item),
              let config = sourceConfig(for: item.sourceID) else { return nil }
        let fingerprint = fingerprint(config)
        let identity = MetadataCache.mergedIdentity("series#\(key)", fingerprint: fingerprint)
        guard let hit = seriesCache[key] ?? cachedEnvelope(identity: identity, config: config),
              hit.sourceFingerprint == fingerprint,
              hit.preferNFO == Preferences.shared.preferNFO else { return nil }
        guard hit.metadataLanguage == TMDBClient.language else { return nil }
        seriesCache[key] = hit
        return hit
    }

    /// Read only: supplement cached library records with verified TMDB cache fields.
    func libraryMetadata(for item: MediaItem, isSeries: Bool = false) -> MediaMetadata? {
        let local = isSeries ? cachedSeriesMetadata(for: item) : metadata(for: item.id)
        guard let config = sourceConfig(for: item.sourceID) else { return local }
        let scope = fingerprint(config)
        let prefix: String
        if isSeries {
            guard let key = Self.seriesKey(for: item) else { return local }
            prefix = "tmdb-series#\(key)"
        } else { prefix = "tmdb-item#\(item.id)" }
        let identity = "\(prefix)#\(TMDBClient.language)#\(scope)"
        let remote = remoteCache[identity] ?? cachedEnvelope(identity: identity, config: config)
        return MetadataMerge.merge(preferred: local, fallback: remote, itemID: item.id)
    }

    func libraryMetadata(for group: SeriesGroup) -> MediaMetadata? {
        let ordered = group.items.sorted {
            ($0.season ?? 0, $0.episode ?? 0, $0.id) < ($1.season ?? 0, $1.episode ?? 0, $1.id)
        }
        var result: MediaMetadata?
        var seen = Set<String>()
        for item in ordered {
            guard let key = Self.seriesKey(for: item), seen.insert(key).inserted else { continue }
            guard let record = libraryMetadata(for: item, isSeries: true) else { continue }
            // Use only show records, never infer show ratings/certification from episode scores.
            result = MetadataMerge.merge(preferred: result, fallback: record,
                                         itemID: group.posterItem?.id ?? item.id)
        }
        return result
    }

    func seriesMetadata(for item: MediaItem, in store: AppStore) async -> MediaMetadata? {
        sourceStore = store
        guard item.kind == .episode else { return nil }
        if requests[item.id] == nil, !interimItems.contains(item.id),
           let hit = cachedSeriesMetadata(for: item) { return hit }
        await load(for: item, in: store)
        return cachedSeriesMetadata(for: item)
    }

    func refresh(for item: MediaItem, in store: AppStore) async {
        await load(for: item, in: store, force: true)
    }

    func invalidate(items list: [MediaItem]) {
        diskLookups.removeAll()
        diskMisses.removeAll()
        var staleIdentities: Set<String> = []
        var currentScopes: Set<String> = []
        for item in list {
            requests[item.id]?.task.cancel()
            requests[item.id] = nil
            inFlight.remove(item.id)
            var records = [items[item.id]].compactMap { $0 }
            if let series = cachedSeriesMetadata(for: item) {
                records.append(series)
            }
            for record in records {
                for (field, path) in [("posterPath", record.posterPath), ("backdropPath", record.backdropPath)] {
                    guard let path, !path.hasPrefix("http"),
                          record.fieldSources?[field] == "nfo" || (record.fieldSources?[field] == nil && record.source == "nfo") else { continue }
                    try? FileManager.default.removeItem(at: MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: path, sourceID: item.sourceID)))
                }
            }
            items[item.id] = nil
            interimItems.remove(item.id)
            loadState[item.id] = nil
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(Self.fileName(item.id)))
            let scope = sourceConfig(for: item.sourceID).map { fingerprint($0) }
            if let scope { currentScopes.insert(scope) }
            MetadataCache.invalidateMerged(identity: "item#\(item.id)", fingerprint: scope)
            staleIdentities.insert("item#\(item.id)")
            if let key = Self.seriesKey(for: item) {
                seriesCache[key] = nil
                MetadataCache.invalidateMerged(identity: "series#\(key)", fingerprint: scope)
                staleIdentities.insert("series#\(key)")
            }
        }
        MetadataCache.sweepStaleMerged(identities: staleIdentities, currentFingerprints: currentScopes)
        for sourceID in Set(list.map(\.sourceID)) { MetadataCache.invalidateSourceImages(sourceID) }
        revision &+= 1
    }

    func artworkMetadata(for item: MediaItem) -> MediaMetadata? {
        cachedSeriesMetadata(for: item) ?? metadata(for: item.id)
    }

    func cachedPosterURL(for item: MediaItem) -> URL? {
        let meta = artworkMetadata(for: item)
        return imageURL(path: meta?.posterPath, itemID: item.id, size: "w500", metadata: meta)
    }

    func backdropURL(for item: MediaItem) -> URL? {
        let meta = artworkMetadata(for: item)
        return imageURL(path: meta?.backdropPath, itemID: item.id, size: "w1280", metadata: meta)
    }

    private func imageURL(path: String?, itemID: String, size: String,
                          metadata supplied: MediaMetadata? = nil) -> URL? {
        guard let path else { return nil }
        let sourceID = UUID(uuidString: String(itemID.split(separator: "#").first ?? "")) ?? UUID()
        let metadata = supplied ?? items[itemID]
        let field = size == "w500" ? "posterPath" : "backdropPath"
        let isLocal = metadata?.fieldSources?[field] == "nfo" || (metadata?.fieldSources?[field] == nil && metadata?.source == "nfo")
        let remotePath = path.hasPrefix("http") || isLocal ? path : "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? "" : "/")\(path)"
        let local = MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: remotePath, sourceID: sourceID))
        if MetadataCache.validImage(at: local) { return local }
        return isLocal && !path.hasPrefix("http") ? nil : URL(string: remotePath)
    }

    func cachedPosterURL(for itemID: String) -> URL? {
        let meta = artworkMetadata(for: itemID)
        return imageURL(path: meta?.posterPath, itemID: itemID, size: "w500", metadata: meta)
    }

    func backdropURL(for itemID: String) -> URL? {
        let meta = artworkMetadata(for: itemID)
        return imageURL(path: meta?.backdropPath, itemID: itemID, size: "w1280", metadata: meta)
    }

    private func artworkMetadata(for itemID: String) -> MediaMetadata? {
        guard let meta = metadata(for: itemID) else { return nil }
        return cachedSeriesRecord(for: meta) ?? meta
    }

    private func cachedSeriesRecord(for meta: MediaMetadata) -> MediaMetadata? {
        guard let key = meta.seriesCacheKey, let fingerprint = meta.sourceFingerprint,
              let sourceID = UUID(uuidString: String(meta.itemID.split(separator: "#").first ?? "")),
              let config = sourceConfig(for: sourceID),
              fingerprint == self.fingerprint(config) else { return nil }
        let identity = MetadataCache.mergedIdentity("series#\(key)", fingerprint: fingerprint)
        // seriesCache / cachedEnvelope 均为内存记忆化，避免渲染时每张卡片都读盘 + 解码 JSON
        guard let series = seriesCache[key] ?? cachedEnvelope(identity: identity, config: config),
              series.sourceFingerprint == fingerprint,
              series.preferNFO == Preferences.shared.preferNFO,
              series.metadataLanguage == TMDBClient.language else { return nil }
        return series
    }

    // MARK: 刮削

    /// 单个条目：优先本地 .nfo，其次 TMDB。已有缓存则跳过。
    func load(for item: MediaItem, in store: AppStore, force: Bool = false) async {
        sourceStore = store
        let preferNFO = Preferences.shared.preferNFO
        let sourceConfig = store.source(for: item.sourceID)
        let artworkRevision = store.artworkRevision
        if let current = requests[item.id] {
            if !force, !current.task.isCancelled,
               current.context.hasSameInputs(preferNFO: preferNFO,
                                             sourceConfig: sourceConfig,
                                             artworkRevision: artworkRevision) {
                requests[item.id]?.waiterCount += 1
                await waitForRequest(current.task, itemID: item.id,
                                     requestID: current.context.id)
                return
            }
            current.task.cancel()
        }
        if !force, requests[item.id] == nil, !interimItems.contains(item.id),
           let cached = metadata(for: item.id),
           cached.cacheVersion == Self.cacheVersion,
           cached.preferNFO == preferNFO, cached.metadataLanguage == TMDBClient.language {
            return
        }

        let context = RequestContext(id: UUID(), preferNFO: preferNFO,
                                     sourceConfig: sourceConfig,
                                     artworkRevision: artworkRevision, language: TMDBClient.language, force: force)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(for: item, in: store, force: force, context: context)
        }
        requests[item.id] = InFlightRequest(context: context, task: task, waiterCount: 1)
        inFlight.insert(item.id)
        loadState[item.id] = MetadataLoadState(isLoading: true, text: "正在读取本地元数据")
        await waitForRequest(task, itemID: item.id, requestID: context.id)
    }

    private func waitForRequest(_ task: Task<Void, Never>, itemID: String,
                                requestID: UUID) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(itemID: itemID, requestID: requestID)
            }
        }
    }

    private func cancelWaiter(itemID: String, requestID: UUID) {
        guard var current = requests[itemID],
              current.context.id == requestID else { return }
        current.waiterCount -= 1
        requests[itemID] = current
        if current.waiterCount == 0 {
            current.task.cancel()
        }
    }

    private func performLoad(for item: MediaItem, in store: AppStore, force: Bool,
                             context: RequestContext) async {
        defer { finishRequest(itemID: item.id, requestID: context.id) }
        guard isCurrent(context, for: item, in: store) else { return }

        var local = await NFOParser.metadata(for: item, in: store)
        let seriesKey = Self.seriesKey(for: item)
        guard isCurrent(context, for: item, in: store),
              let config = context.sourceConfig, let source = try? MediaSourceFactory.make(config) else { return }
        let scope = MetadataCache.sourceFingerprint(config)
        let itemIdentity = MetadataCache.mergedIdentity("item#\(item.id)", fingerprint: scope)
        let seriesIdentity = seriesKey.map { MetadataCache.mergedIdentity("series#\($0)", fingerprint: scope) }
        if force {
            invalidateLocalImages([metadata(for: item.id), cachedSeriesMetadata(for: item), local].compactMap { $0 },
                                  sourceID: item.sourceID)
        }
        func publishLocal(_ local: MediaMetadata?, series: MediaMetadata?) {
            guard isCurrent(context, for: item, in: store) else { return }
            var series = series
            if var record = series, let key = seriesKey {
                stamp(&record, context: context)
                seriesCache[key] = record
                series = record
            }
            let record = seriesKey == nil ? local : MetadataMerge.episode(local: local, series: series, item: item)
            if var value = record {
                value.seriesCacheKey = seriesKey
                stamp(&value, context: context)
                interimItems.insert(item.id)
                commit(value, context: context, item: item, store: store)
            }
        }
        // Publish each local scope before reading the next scope or awaiting supplementation.
        publishLocal(local, series: nil)
        var localSeries = seriesKey == nil ? nil : await NFOParser.seriesMetadata(for: item, in: store)
        guard isCurrent(context, for: item, in: store) else { return }
        if force, let localSeries { invalidateLocalImages([localSeries], sourceID: item.sourceID) }
        publishLocal(local, series: localSeries)
        if local == nil, TMDBClient.apiKey == nil {
            local = await MetadataCache.restore(identity: itemIdentity, source: source) {
                self.isCurrent(context, for: item, in: store)
            }
            publishLocal(local, series: localSeries)
        }
        if localSeries == nil, TMDBClient.apiKey == nil, let seriesIdentity {
            localSeries = await MetadataCache.restore(identity: seriesIdentity, source: source) {
                self.isCurrent(context, for: item, in: store)
            }
            publishLocal(local, series: localSeries)
        }
        let identity = (seriesKey.map { "tmdb-series#\($0)#\(context.language)" } ?? "tmdb-item#\(item.id)#\(context.language)") + "#\(scope)"
        var remote = remoteCache[identity]
        if remote == nil {
            remote = await MetadataCache.restore(identity: identity, source: source) {
                self.isCurrent(context, for: item, in: store)
            }
        }
        guard isCurrent(context, for: item, in: store) else { return }
        if let remote { remoteCache[identity] = remote }
        if TMDBClient.apiKey != nil && (force || remote == nil) {
            loadState[item.id]?.text = "正在通过 TMDB 补充元数据"
            do {
                let query = item.seriesTitle ?? local?.title ?? item.title
                if let key = seriesKey {
                    let requestKey = "\(key)#\(scope)#\(context.artworkRevision)#\(context.language)"
                    let request: SeriesRequest
                    if !force, seriesMisses.contains(requestKey) {
                        request = SeriesRequest(task: Task { nil })
                    } else if !force, let existing = seriesRequests[requestKey] { request = existing }
                    else {
                        let client = self.client
                        request = SeriesRequest(task: Task { try await client.scrape(itemID: item.id, query: query,
                                                                                    year: item.year, isSeries: true) })
                        seriesRequests[requestKey] = request
                    }
                    defer {
                        if seriesRequests[requestKey]?.id == request.id { seriesRequests[requestKey] = nil }
                    }
                    let scraped = try await request.task.value
                    guard isCurrent(context, for: item, in: store) else { return }
                    if let scraped { remote = scraped; seriesMisses.remove(requestKey) }
                    else { seriesMisses.insert(requestKey) }
                } else {
                    if let scraped = try await client.scrape(itemID: item.id, query: query,
                                                            year: item.year, isSeries: false) { remote = scraped }
                }
                guard isCurrent(context, for: item, in: store) else { return }
                if let remote {
                    remoteCache[identity] = remote
                }
            } catch {
                guard isCurrent(context, for: item, in: store) else { return }
                lastError = "TMDB 元数据请求失败，已保留可用的本地信息。"
                loadState[item.id]?.error = lastError
            }
        }
        guard isCurrent(context, for: item, in: store) else { return }
        // Refresh is explicitly local-first, even when the normal preference is TMDB-first.
        let localWins = force || context.preferNFO
        func merged(_ nfo: MediaMetadata?) -> MediaMetadata? {
            MetadataMerge.merge(preferred: localWins ? nfo : remote,
                                fallback: localWins ? remote : nfo, itemID: item.id)
        }
        var result: MediaMetadata?
        var finalSeries: MediaMetadata?
        if let key = seriesKey {
            if var series = merged(localSeries) {
                series.mediaType = "tv"
                stamp(&series, context: context)
                seriesCache[key] = series
                finalSeries = series
                result = MetadataMerge.episode(local: local, series: series, item: item)
            } else { result = MetadataMerge.episode(local: local, series: nil, item: item) }
        } else { result = merged(local) }
        guard isCurrent(context, for: item, in: store) else { return }
        if var result {
            result.seriesCacheKey = seriesKey
            stamp(&result, context: context)
            guard commit(result, context: context, item: item, store: store) else { return }
            interimItems.remove(item.id)
            loadState[item.id]?.text = "元数据已更新"
            // Observable item/series publication precedes all disk, NAS and image persistence.
            saveToDisk(result)
            await persist(result, identity: itemIdentity, source: source,
                          item: item, context: context, store: store)
            if let finalSeries, let seriesIdentity {
                await persist(finalSeries, identity: seriesIdentity, source: source,
                              item: item, context: context, store: store)
            }
            if let remote {
                await persist(remote, identity: identity, source: source,
                              item: item, context: context, store: store)
            }
            let publishedItem = result
            let publishedSeries = finalSeries
            async let itemImages: Void = persistImages(publishedItem, source: source, item: item, context: context, store: store, force: force)
            async let seriesImages: Void = persistImages(publishedSeries, source: source, item: item, context: context, store: store, force: force)
            _ = await (itemImages, seriesImages)
        } else { loadState[item.id]?.text = "未找到元数据" }
    }

    private func persist(_ meta: MediaMetadata, identity: String, source: MediaSource,
                         item: MediaItem, context: RequestContext, store: AppStore) async {
        guard isCurrent(context, for: item, in: store) else { return }
        do {
            try await MetadataCache.save(meta, identity: identity, source: source) {
                self.isCurrent(context, for: item, in: store)
            }
        }
        catch {
            guard isCurrent(context, for: item, in: store) else { return }
            loadState[item.id]?.error = "元数据已缓存在本机，但写入媒体源缓存失败。"
        }
    }

    private func invalidateLocalImages(_ records: [MediaMetadata], sourceID: UUID) {
        for record in records {
            var paths: [String] = []
            for (field, path) in [("posterPath", record.posterPath), ("backdropPath", record.backdropPath)] {
                if let path, record.fieldSources?[field] == "nfo"
                    || (record.fieldSources?[field] == nil && record.source == "nfo") { paths.append(path) }
            }
            if record.fieldSources?["cast"] == "nfo" || (record.fieldSources?["cast"] == nil && record.source == "nfo") {
                paths += record.cast.compactMap(\.profilePath)
            }
            for path in paths where !path.hasPrefix("http") {
                try? FileManager.default.removeItem(at: MetadataCache.imageURL(
                    identity: MetadataCache.imageIdentity(path: path, sourceID: sourceID)))
            }
        }
    }

    private func persistImages(_ meta: MediaMetadata?, source: MediaSource, item: MediaItem,
                               context: RequestContext, store: AppStore, force: Bool) async {
        guard let meta, isCurrent(context, for: item, in: store) else { return }
        var paths: Set<String> = []
        for (field, path, size) in [("posterPath", meta.posterPath, "w500"), ("backdropPath", meta.backdropPath, "w1280")] {
            guard let path else { continue }
            let local = meta.fieldSources?[field] == "nfo" || (meta.fieldSources?[field] == nil && meta.source == "nfo")
            let resolved = local || path.hasPrefix("http") ? path : "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? "" : "/")\(path)"
            paths.insert(resolved)
        }
        let localCast = meta.fieldSources?["cast"] == "nfo" || (meta.fieldSources?["cast"] == nil && meta.source == "nfo")
        for member in meta.cast {
            guard let path = member.profilePath, !path.isEmpty else { continue }
            paths.insert(localCast || path.hasPrefix("http") ? path : "https://image.tmdb.org/t/p/w185\(path.hasPrefix("/") ? "" : "/")\(path)")
        }
        // Bounded parallel prefetch: a slow poster cannot hold up backdrop/profile downloads.
        await withTaskGroup(of: Bool.self) { group in
            var iterator = paths.makeIterator()
            func enqueue(_ path: String) {
                group.addTask {
                    do {
                        try await MetadataImageCache.shared.persist(path: path, source: source,
                            force: force && !path.hasPrefix("http")) {
                            self.isCurrent(context, for: item, in: store)
                        }
                        return true
                    } catch { return false }
                }
            }
            for _ in 0..<4 { if let path = iterator.next() { enqueue(path) } }
            for await success in group {
                guard isCurrent(context, for: item, in: store) else { group.cancelAll(); return }
                if !success { loadState[item.id]?.error = "图片已尽量缓存在本机，但写入媒体源缓存失败。" }
                if let path = iterator.next() { enqueue(path) }
            }
        }
    }

    /// 剧集归一化键：去掉季号，用于同剧复用
    private static func seriesKey(for item: MediaItem) -> String? {
        guard let series = item.seriesTitle else { return nil }
        let cleaned = TMDBClient.searchableTitle(series).lowercased()
        guard !cleaned.isEmpty else { return nil }
        return "\(item.sourceID.uuidString.lowercased())#\(cleaned)#\(item.year.map(String.init) ?? "-")"
    }

    /// 批量刮削（扫描完成后调用）
    func scrapeAll(items list: [MediaItem], in store: AppStore, limit: Int = 40) async {
        sourceStore = store
        let preferNFO = Preferences.shared.preferNFO
        let pending = list.filter { item in
            guard let cached = metadata(for: item.id) else { return true }
            return requests[item.id] != nil || interimItems.contains(item.id) || cached.cacheVersion != Self.cacheVersion
                || cached.preferNFO != preferNFO || cached.metadataLanguage != TMDBClient.language
        }
        for item in pending.prefix(limit) {
            await load(for: item, in: store)
            try? await Task.sleep(nanoseconds: 260_000_000)   // 限速，TMDB 40 req/s
        }
    }

    /// 季海报（本地没有时用 TMDB 的季海报）
    func seasonPosterURL(seriesItemID: String, season: Int) async -> URL? {
        guard let meta = metadata(for: seriesItemID) else { return nil }
        let series = cachedSeriesRecord(for: meta)
        guard let tvID = series?.tmdbID ?? meta.tmdbID else { return nil }
        let identity = "season#\(tvID)#\(season)"
        if let cached = MetadataCache.local(identity: identity), let path = cached.posterPath,
           let url = imageURL(path: path, itemID: seriesItemID, size: "w500", metadata: cached) {
            return url
        }
        guard let key = TMDBClient.apiKey else { return nil }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/tv/\(tvID)/season/\(season)")!
        var items: [URLQueryItem] = [.init(name: "language", value: TMDBClient.language)]
        if !TMDBClient.isReadAccessToken(key) { items.append(.init(name: "api_key", value: key)) }
        comps.queryItems = items
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        if TMDBClient.isReadAccessToken(key) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = root["poster_path"] as? String else { return nil }
        guard !Task.isCancelled else { return nil }
        var record = MediaMetadata(itemID: identity)
        record.posterPath = path
        try? await MetadataCache.save(record, identity: identity, source: nil)
        let posterURL = URL(string: "https://image.tmdb.org/t/p/w500\(path)")
        if let posterURL, let (bytes, response) = try? await URLSession.shared.data(from: posterURL),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           MetadataCache.validImage(bytes), !Task.isCancelled {
            try? bytes.write(to: MetadataCache.imageURL(identity: posterURL.absoluteString), options: .atomic)
        }
        return imageURL(path: path, itemID: seriesItemID, size: "w500", metadata: record)
    }

    private func isCurrent(_ context: RequestContext, for item: MediaItem,
                           in store: AppStore) -> Bool {
        !Task.isCancelled
            && requests[item.id]?.context == context
            && Preferences.shared.preferNFO == context.preferNFO
            && store.source(for: item.sourceID) == context.sourceConfig
            && store.artworkRevision == context.artworkRevision
            && TMDBClient.language == context.language
    }

    @discardableResult
    private func commit(_ meta: MediaMetadata, seriesKey: String? = nil,
                        context: RequestContext, item: MediaItem, store: AppStore) -> Bool {
        guard isCurrent(context, for: item, in: store) else { return false }
        items[item.id] = meta
        if let seriesKey { seriesCache[seriesKey] = meta }
        revision &+= 1
        return true
    }

    private func finishRequest(itemID: String, requestID: UUID) {
        guard requests[itemID]?.context.id == requestID else { return }
        requests[itemID] = nil
        inFlight.remove(itemID)
        loadState[itemID]?.isLoading = false
        if Task.isCancelled { loadState[itemID]?.text = "已取消" }
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
               let meta = try? decoder.decode(MediaMetadata.self, from: data),
               meta.cacheVersion == Self.cacheVersion,
               meta.preferNFO == Preferences.shared.preferNFO,
               meta.metadataLanguage == TMDBClient.language,
               let sourceID = UUID(uuidString: String(meta.itemID.split(separator: "#").first ?? "")),
               let config = sourceConfig(for: sourceID),
               meta.sourceFingerprint == fingerprint(config) {
                items[meta.itemID] = meta
            }
        }
    }

    private func stamp(_ meta: inout MediaMetadata, context: RequestContext) {
        meta.cacheVersion = Self.cacheVersion
        meta.preferNFO = context.preferNFO
        meta.metadataLanguage = context.language
        meta.sourceFingerprint = context.sourceConfig.map(MetadataCache.sourceFingerprint)
        // Forced refresh changes same-path artwork identity without a library-wide revision.
        if context.force { meta.artworkRefreshID = context.id.uuidString }
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
        return await read(candidates: item.kind == .episode ? ["\(stem).nfo"] : ["\(stem).nfo", "movie.nfo"],
                          dir: dir, itemID: item.id, source: source)
    }

    @MainActor
    static func seriesMetadata(for item: MediaItem, in store: AppStore) async -> MediaMetadata? {
        guard item.kind == .episode, let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else { return nil }
        var dir = (item.path as NSString).deletingLastPathComponent
        // Season directory plus at most two ancestors; never escape the source root.
        for _ in 0..<3 {
            guard !Task.isCancelled else { return nil }
            if let result = await read(candidates: ["tvshow.nfo"], dir: dir,
                                       itemID: item.id, source: source) { return result }
            if dir.isEmpty { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func read(candidates: [String], dir: String, itemID: String,
                             source: MediaSource) async -> MediaMetadata? {
        guard !Task.isCancelled, let entries = try? await source.list(path: dir) else { return nil }
        let files = entries.filter { !$0.isDirectory }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            guard let entry = files.first(where: { $0.name.lowercased() == candidate.lowercased() }),
                  let data = try? await source.data(for: entry.path),
                  var meta = NFXMLDecoder.decode(data, itemID: itemID) else { continue }
            func image(_ value: String?, variant: ArtworkVariant) -> String? {
                if let value, value.hasPrefix("https://") || value.hasPrefix("http://") { return value }
                if let value, let match = files.first(where: {
                    $0.name.lowercased() == (value as NSString).lastPathComponent.lowercased()
                }) { return match.path }
                let stem = (entry.name as NSString).deletingPathExtension
                guard let name = ArtworkMatcher.match(names: files.map(\.name), stem: stem,
                                                       variant: variant),
                      let match = files.first(where: { $0.name == name }) else { return nil }
                return match.path
            }
            meta.posterPath = image(meta.posterPath, variant: .poster)
            meta.backdropPath = image(meta.backdropPath, variant: .backdrop)
            for index in meta.cast.indices {
                guard let path = meta.cast[index].profilePath, !path.hasPrefix("http") else { continue }
                // Preserve source-relative actor paths, resolving same-directory names from the listing.
                if let match = files.first(where: { $0.name.caseInsensitiveCompare(path) == .orderedSame }) {
                    meta.cast[index].profilePath = match.path
                } else if !dir.isEmpty, !path.hasPrefix(dir + "/"), !path.hasPrefix("/") {
                    meta.cast[index].profilePath = "\(dir)/\(path)"
                }
            }
            return Task.isCancelled ? nil : meta
        }
        return nil
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

    private static let keyLock = NSLock()
    private static var cachedKey: String?
    private static var keyLoaded = false

    /// 启动/刮削/多个视图都会读 TMDB key；缓存首次读取，避免重复访问钥匙串。
    static var apiKey: String? {
        keyLock.lock()
        defer { keyLock.unlock() }
        if keyLoaded { return cachedKey }
        var value = Keychain.get(account: keyAccount)
        if value?.isEmpty != false {
            #if DEBUG
            if let legacy = UserDefaults.standard.string(forKey: keyAccount), !legacy.isEmpty {
                if Keychain.set(legacy, account: keyAccount) {
                    UserDefaults.standard.removeObject(forKey: keyAccount)
                }
                value = legacy
            } else {
                value = nil
            }
            #else
            value = nil
            #endif
        }
        cachedKey = value?.isEmpty == false ? value : nil
        keyLoaded = true
        return cachedKey
    }

    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        if key.isEmpty { Keychain.delete(account: keyAccount) }
        else if !Keychain.set(key, account: keyAccount) { return false }
        keyLock.lock()
        cachedKey = key.isEmpty ? nil : key
        keyLoaded = true
        keyLock.unlock()
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: keyAccount)
        #endif
        return true
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

    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: cfg)
        }
    }

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
            .init(name: "append_to_response", value: isSeries ? "credits,content_ratings" : "credits,release_dates")
        ])
        detailComps.queryItems = detailItems
        let detailData = try await get(detailComps.url!, bearer: usesBearer ? key : nil)
        guard let d = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] else {
            throw TMDBError.decode
        }

        var meta = MediaMetadata(itemID: itemID)
        meta.tmdbID = d["id"] as? Int
        meta.title = d["title"] as? String ?? d["name"] as? String
        meta.seriesTitle = isSeries ? (d["name"] as? String) : nil
        meta.mediaType = isSeries ? "tv" : "movie"
        meta.originalTitle = d["original_title"] as? String ?? d["original_name"] as? String
        meta.overview = d["overview"] as? String
        meta.voteCount = d["vote_count"] as? Int
        if (meta.voteCount ?? 0) > 0, let value = d["vote_average"] as? Double,
           (0...10).contains(value) { meta.rating = value }
        meta.runtimeMinutes = d["runtime"] as? Int ?? (d["episode_run_time"] as? [Int])?.first
        let ratingRoot = d[isSeries ? "content_ratings" : "release_dates"] as? [String: Any]
        let countries = ratingRoot?["results"] as? [[String: Any]] ?? []
        var certificates: [(country: String, rating: String)] = []
        for country in countries {
            guard let code = country["iso_3166_1"] as? String else { continue }
            let values = isSeries ? [country] : (country["release_dates"] as? [[String: Any]] ?? [])
            for value in values {
                if let rating = value[isSeries ? "rating" : "certification"] as? String,
                   !rating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    certificates.append((code, rating))
                }
            }
        }
        let preferredRegion = Self.language.split(separator: "-").last.map(String.init)?.uppercased()
        if let certificate = certificates.first(where: { $0.country == preferredRegion })
            ?? certificates.first(where: { $0.country == "US" }) ?? certificates.first {
            meta.certification = certificate.rating
            meta.certificationRegion = certificate.country
        }
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
