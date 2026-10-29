import Foundation

/// 解析片源目录里已有的本地图片。
///
/// 覆盖 Emby / Jellyfin / Kodi / tinyMediaManager 的常见命名：
///   `<stem>-poster.jpg` / `<stem>-fanart.jpg` / `<stem>-landscape.png` / `<stem>-thumb.jpg`
///   `poster.jpg` / `folder.jpg` / `cover.jpg` / `fanart.jpg` / `backdrop.jpg` / `thumb.jpg`
///   `season01-poster.jpg` / `tvshow.nfo`
@MainActor
final class LocalArtworkResolver {
    static let shared = LocalArtworkResolver()

    private var cache: [String: String] = [:]          // "sourceID#itemID#variant" -> path
    private var directoryCache: [String: [String]] = [:]  // "sourceID#dir" -> 真实文件名
    private var generation = 0

    func path(for item: MediaItem, variant: ArtworkVariant, in store: AppStore) async -> String? {
        let key = "\(item.sourceID.uuidString)#\(item.id)#\(variantKey(variant))"
        if let hit = cache[key] { return hit }
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else { return nil }
        let requestGeneration = generation

        let dir = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension

        var result = await search(dir: dir, stem: stem, variant: variant, source: source,
                                  generation: requestGeneration)
        guard isCurrent(requestGeneration) else { return nil }

        // 剧集：本目录没有就往上找（季目录 → 剧集根目录）
        if result == nil, item.seriesTitle != nil {
            let parent = (dir as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != dir {
                result = await search(dir: parent, stem: stem, variant: variant,
                                      source: source, isParent: true,
                                      generation: requestGeneration)
                guard isCurrent(requestGeneration) else { return nil }
                if result == nil {
                    let grand = (parent as NSString).deletingLastPathComponent
                    if !grand.isEmpty, grand != parent {
                        result = await search(dir: grand, stem: stem, variant: variant,
                                              source: source, isParent: true,
                                              generation: requestGeneration)
                        guard isCurrent(requestGeneration) else { return nil }
                    }
                }
            }
        }

        if let result, isCurrent(requestGeneration) {
            cache[key] = result
        }
        return isCurrent(requestGeneration) ? result : nil
    }

    /// 季海报：在季目录及其上两级里找 seasonNN-poster.jpg / season N-poster.jpg
    func seasonPosterPath(for item: MediaItem, season: Int, in store: AppStore) async -> String? {
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else { return nil }
        let key = "\(item.sourceID.uuidString)#\(item.id)#season\(season)"
        if let hit = cache[key] { return hit }
        let requestGeneration = generation

        let names = [
            String(format: "season%02d-poster.jpg", season),
            String(format: "season%d-poster.jpg", season),
            String(format: "season%02d-poster.png", season),
            String(format: "season-%02d-poster.jpg", season),
            String(format: "season %d-poster.jpg", season)
        ]

        var dir = (item.path as NSString).deletingLastPathComponent
        for _ in 0..<3 {
            guard isCurrent(requestGeneration) else { return nil }
            let listing = await listing(dir: dir, source: source,
                                        generation: requestGeneration)
            guard isCurrent(requestGeneration) else { return nil }
            let lower = Set(listing.map { $0.lowercased() })
            for candidate in names where lower.contains(candidate.lowercased()) {
                let real = listing.first { $0.lowercased() == candidate.lowercased() } ?? candidate
                let full = dir.isEmpty ? real : "\(dir)/\(real)"
                cache[key] = full
                return full
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// 清缓存（重新扫描后调用）
    func invalidate() {
        generation &+= 1
        cache.removeAll()
        directoryCache.removeAll()
    }

    // MARK: 具体规则

    private func search(dir: String, stem: String, variant: ArtworkVariant,
                        source: MediaSource, isParent: Bool = false,
                        generation requestGeneration: Int) async -> String? {
        guard isCurrent(requestGeneration) else { return nil }
        let names = await listing(dir: dir, source: source,
                                  generation: requestGeneration)
        guard isCurrent(requestGeneration) else { return nil }
        guard !names.isEmpty else { return nil }

        if let name = Self.match(names: names, stem: stem, variant: variant,
                                 season: isParent ? seasonNumber(from: dir) : nil) {
            return dir.isEmpty ? name : "\(dir)/\(name)"
        }
        return nil
    }

    /// 委托给纯逻辑（ArtworkMatcher，可单测）
    static func match(names: [String], stem: String, variant: ArtworkVariant,
                      season: Int? = nil) -> String? {
        ArtworkMatcher.match(names: names, stem: stem, variant: variant, season: season)
    }

    private func listing(dir: String, source: MediaSource,
                         generation requestGeneration: Int) async -> [String] {
        guard isCurrent(requestGeneration) else { return [] }
        let key = "\(source.config.id.uuidString)#\(dir)"
        if let hit = directoryCache[key] { return hit }
        // 关键：列目录失败时**不能缓存空结果**，否则这个目录整个会话都查不到图，
        // 缩略图会静默回落到刮削海报 —— 表现就是"每集封面都一样"。
        guard let entries = try? await source.list(path: dir) else {
            AppLog.error("LocalArtwork 列目录失败（不缓存）：\(dir)")
            return []
        }
        guard isCurrent(requestGeneration) else { return [] }
        let names = entries.filter { !$0.isDirectory }.map(\.name)
        directoryCache[key] = names
        return names
    }

    private func isCurrent(_ requestGeneration: Int) -> Bool {
        !Task.isCancelled && generation == requestGeneration
    }

    /// 从 `S01` / `Season 1` / `第一季` 里取季号
    private func seasonNumber(from dir: String) -> Int? {
        ArtworkMatcher.seasonNumber(fromDirectoryName: (dir as NSString).lastPathComponent)
    }

    private func variantKey(_ v: ArtworkVariant) -> String {
        switch v {
        case .poster:   return "p"
        case .backdrop: return "b"
        case .thumb:    return "t"
        }
    }
}
