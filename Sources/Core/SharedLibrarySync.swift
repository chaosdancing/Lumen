import Foundation

// MARK: - 共享格式

/// 写入每个媒体源根目录 `.lumen-cache/library-metadata.json`。
/// 所有 Lumen 设备（以及能读这份 JSON 的其它工具）可以共享同一套刮削结果。
struct SharedMetadataCatalog: Codable {
    var schema = 1
    var updatedAt = Date()
    var entries: [String: SharedMetadataEntry] = [:]
}

/// 与安装相关的字段（itemID、sourceFingerprint）不写进共享文件；
/// 只保留可跨设备复用的影片信息。
struct SharedMetadataEntry: Codable {
    var title: String?
    var originalTitle: String?
    var seriesTitle: String?
    var overview: String?
    var rating: Double?
    var voteCount: Int?
    var genres: [String] = []
    var cast: [CastMember] = []
    var posterPath: String?
    var backdropPath: String?
    var releaseDate: String?
    var certification: String?
    var certificationRegion: String?
    var runtimeMinutes: Int?
    var mediaType: String?
    var tmdbID: Int?
    var updatedAt = Date()

    init(meta: MediaMetadata) {
        title = meta.title
        originalTitle = meta.originalTitle
        seriesTitle = meta.seriesTitle
        overview = meta.overview
        rating = meta.rating
        voteCount = meta.voteCount
        genres = meta.genres
        cast = meta.cast
        posterPath = meta.posterPath
        backdropPath = meta.backdropPath
        releaseDate = meta.releaseDate
        certification = meta.certification
        certificationRegion = meta.certificationRegion
        runtimeMinutes = meta.runtimeMinutes
        mediaType = meta.mediaType
        tmdbID = meta.tmdbID
        updatedAt = meta.updatedAt
    }

    /// 没有类型/简介/海报的共享记录仍然让本机去补 TMDB，避免把 NFO 的残缺信息当成完整刮削。
    var isComplete: Bool {
        !genres.isEmpty && posterPath?.isEmpty == false && overview?.isEmpty == false
    }

    func metadata(for item: MediaItem, sourceFingerprint: String,
                  cacheVersion: Int, preferNFO: Bool, language: String) -> MediaMetadata {
        var meta = MediaMetadata(itemID: item.id)
        meta.tmdbID = tmdbID
        meta.seriesTitle = seriesTitle ?? item.seriesTitle
        meta.title = title ?? item.title
        meta.originalTitle = originalTitle
        meta.overview = overview
        meta.rating = rating
        meta.voteCount = voteCount
        meta.genres = genres
        meta.cast = cast
        meta.posterPath = posterPath
        meta.backdropPath = backdropPath
        meta.releaseDate = releaseDate
        meta.certification = certification
        meta.certificationRegion = certificationRegion
        meta.mediaType = mediaType ?? (item.kind == .episode ? "tv" : "movie")
        meta.runtimeMinutes = runtimeMinutes
        meta.cacheVersion = cacheVersion
        meta.preferNFO = preferNFO
        meta.metadataLanguage = language
        meta.sourceFingerprint = sourceFingerprint
        meta.source = "shared"
        meta.updatedAt = updatedAt
        return meta
    }
}

/// 写入每个媒体源根目录 `.lumen-cache/library-state.json`。
/// key 使用源内相对路径，不同安装/不同机器只要扫描到同一目录就能对应。
struct SharedLibraryState: Codable {
    var schema = 1
    var updatedAt = Date()
    var progress: [String: SharedProgress] = [:]
    var favorites: [String: SharedFavorite] = [:]
}

struct SharedProgress: Codable {
    var position: Double
    var duration: Double
    var updatedAt: Date
}

struct SharedFavorite: Codable {
    var favorite: Bool
    var updatedAt: Date
}

// MARK: - 同步器

/// 把刮削结果与观看状态写入媒体源的 `.lumen-cache`，并在扫描时反向导入。
/// 所有操作都在主线程；网络写盘是 await，失败只记日志，不影响播放。
@MainActor
final class SharedLibrarySync {
    static let shared = SharedLibrarySync()

    static let metadataPath = ".lumen-cache/library-metadata.json"
    static let statePath = ".lumen-cache/library-state.json"

    private init() {}

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var pendingMetadataSources: Set<UUID> = []
    private var pendingStateSources: Set<UUID> = []
    private var metadataTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    // MARK: 调度

    func scheduleMetadata(store: AppStore, sourceID: UUID) {
        guard Preferences.shared.shareMetadataToSource else { return }
        pendingMetadataSources.insert(sourceID)
        metadataTask?.cancel()
        metadataTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.metadataTask = nil
            await self.flushMetadata(store: store)
        }
    }

    func scheduleState(store: AppStore) {
        guard Preferences.shared.sharePlaybackStateToSource else { return }
        for source in store.sources where source.kind != .emby && source.kind != .jellyfin {
            pendingStateSources.insert(source.id)
        }
        guard stateTask == nil, !pendingStateSources.isEmpty else { return }
        stateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            self.stateTask = nil
            await self.flushState(store: store)
            if !self.pendingStateSources.isEmpty {
                self.scheduleState(store: store)
            }
        }
    }

    /// 关闭播放器、进入后台、退出时调用，尽量把共享状态立即落盘。
    func flush(store: AppStore) async {
        metadataTask?.cancel(); metadataTask = nil
        stateTask?.cancel(); stateTask = nil
        await flushMetadata(store: store)
        for source in store.sources {
            pendingStateSources.insert(source.id)
        }
        await flushState(store: store)
    }

    // MARK: 导入

    /// 扫描完成后调用：先导入共享元数据，再导入进度/收藏。
    func importAll(source: MediaSource, items: [MediaItem],
                   config: MediaSourceConfig, store: AppStore) async {
        if Preferences.shared.shareMetadataToSource,
           let data = try? await source.data(for: Self.metadataPath),
           let catalog = try? decoder.decode(SharedMetadataCatalog.self, from: data),
           catalog.schema == 1 {
            MetadataStore.shared.importSharedCatalog(catalog, items: items, config: config)
        }
        guard Preferences.shared.sharePlaybackStateToSource,
              let data = try? await source.data(for: Self.statePath),
              let state = try? decoder.decode(SharedLibraryState.self, from: data),
              state.schema == 1 else { return }
        var records: [String: PlaybackRecord] = [:]
        var favoriteIDs = Set<String>()
        for item in items {
            if let progress = state.progress[item.path] {
                let local = store.record(for: item.id)
                if local == nil || progress.updatedAt > local!.updatedAt {
                    records[item.id] = PlaybackRecord(itemID: item.id,
                                                      position: progress.position,
                                                      duration: progress.duration,
                                                      updatedAt: progress.updatedAt)
                }
            }
            if state.favorites[item.path]?.favorite == true {
                favoriteIDs.insert(item.id)
            }
        }
        store.applyShared(progress: records, favoriteIDs: favoriteIDs)
        // 把本机已有、但媒体源上还没有的进度/收藏补写回去；内容相同会在 writeState 内跳过。
        scheduleState(store: store)
    }

    /// 已有 library.json 的启动路径：不重新扫描也能把 NAS 上的进度/收藏读回来。
    func importExisting(store: AppStore) async {
        let grouped = Dictionary(grouping: store.library, by: \.sourceID)
        for config in store.sources {
            guard let items = grouped[config.id], !items.isEmpty,
                  let source = try? MediaSourceFactory.make(config) else { continue }
            await importAll(source: source, items: items, config: config, store: store)
        }
    }

    // MARK: 写元数据

    private func flushMetadata(store: AppStore) async {
        guard Preferences.shared.shareMetadataToSource else {
            pendingMetadataSources.removeAll()
            return
        }
        let ids = pendingMetadataSources
        pendingMetadataSources.removeAll()
        for id in ids {
            guard let config = store.source(for: id) else { continue }
            await writeMetadata(store: store, config: config)
        }
    }

    private func writeMetadata(store: AppStore, config: MediaSourceConfig) async {
        guard config.kind != .emby, config.kind != .jellyfin,
              let source = try? MediaSourceFactory.make(config),
              let writable = source as? WritableMediaSource else { return }
        var catalog = SharedMetadataCatalog()
        var existingData: Data?
        if let data = try? await source.data(for: Self.metadataPath),
           let existing = try? decoder.decode(SharedMetadataCatalog.self, from: data),
           existing.schema == 1 {
            catalog = existing
            existingData = data
        }
        for item in store.library where item.sourceID == config.id {
            let meta = MetadataStore.shared.libraryMetadata(for: item, isSeries: item.kind == .episode)
                ?? MetadataStore.shared.metadata(for: item.id)
            guard let meta else { continue }
            catalog.entries[item.path] = SharedMetadataEntry(meta: meta)
        }
        catalog.updatedAt = Date()
        guard !catalog.entries.isEmpty, let data = try? encoder.encode(catalog) else { return }
        if data == existingData { return }
        do {
            try await writable.writeShared(data, path: Self.metadataPath)
            AppLog.info("共享元数据写入 \(config.name) entries=\(catalog.entries.count)")
        } catch {
            AppLog.error("共享元数据写入失败 \(config.name)：\(error.logDescription)")
        }
    }

    // MARK: 写进度/收藏

    private func flushState(store: AppStore) async {
        guard Preferences.shared.sharePlaybackStateToSource else {
            pendingStateSources.removeAll()
            return
        }
        let ids = pendingStateSources
        pendingStateSources.removeAll()
        for id in ids {
            guard let config = store.source(for: id) else { continue }
            await writeState(store: store, config: config)
        }
    }

    private func writeState(store: AppStore, config: MediaSourceConfig) async {
        guard config.kind != .emby, config.kind != .jellyfin,
              let source = try? MediaSourceFactory.make(config),
              let writable = source as? WritableMediaSource else { return }
        var state = SharedLibraryState()
        var existingData: Data?
        if let data = try? await source.data(for: Self.statePath),
           let existing = try? decoder.decode(SharedLibraryState.self, from: data),
           existing.schema == 1 {
            state = existing
            existingData = data
        }
        let now = Date()
        for item in store.library where item.sourceID == config.id {
            if let record = store.record(for: item.id) {
                if state.progress[item.path] == nil || record.updatedAt > state.progress[item.path]!.updatedAt {
                    state.progress[item.path] = SharedProgress(position: record.position,
                                                              duration: record.duration,
                                                              updatedAt: record.updatedAt)
                }
            }
        }
        for group in store.seriesGroups {
            let groupItems = group.items.filter { $0.sourceID == config.id }
            guard !groupItems.isEmpty, store.isSeriesFavorite(group) else { continue }
            // 剧集收藏在本地只用任意一集代表；写入共享时标全部分集，其他设备才能识别整部剧。
            for item in groupItems {
                state.favorites[item.path] = SharedFavorite(favorite: true, updatedAt: now)
            }
        }
        for item in store.library where item.sourceID == config.id && item.kind == .movie {
            if store.isFavorite(item.id) {
                state.favorites[item.path] = SharedFavorite(favorite: true, updatedAt: now)
            }
        }
        state.updatedAt = now
        guard !state.progress.isEmpty || !state.favorites.isEmpty,
              let data = try? encoder.encode(state) else { return }
        if data == existingData { return }
        do {
            try await writable.writeShared(data, path: Self.statePath)
            AppLog.info("共享状态写入 \(config.name) progress=\(state.progress.count) favorites=\(state.favorites.count)")
        } catch {
            AppLog.error("共享状态写入失败 \(config.name)：\(error.logDescription)")
        }
    }
}
