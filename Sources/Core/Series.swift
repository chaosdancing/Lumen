import Foundation

/// 一部剧 = 多集聚合。VidHub 的核心体验就在这层：媒体库里一张卡片代表一部剧，
/// 点进去才按季/集展开。之前我把每个文件都当独立条目平铺，等于没有"剧集"概念。
struct SeriesGroup: Identifiable {
    let id: String
    let title: String
    var items: [MediaItem]

    var seasons: [Int] {
        Array(Set(items.compactMap(\.season))).sorted()
    }

    var episodeCount: Int { items.count }

    var seasonSummary: String {
        let s = seasons
        guard !s.isEmpty else { return "\(episodeCount) 集" }
        if s.count == 1 { return "第 \(s[0]) 季 · \(episodeCount) 集" }
        return "\(s.count) 季 · \(episodeCount) 集"
    }

    /// 用第一集（S01E01）的封面当剧集封面
    var posterItem: MediaItem? {
        items.min { lhs, rhs in
            (lhs.season ?? 0, lhs.episode ?? 0) < (rhs.season ?? 0, rhs.episode ?? 0)
        }
    }

    /// 继续观看用：取有进度且未看完的最新一集
    func nextEpisode(progress: [String: PlaybackRecord]) -> MediaItem? {
        let inProgress = items
            .compactMap { item -> (MediaItem, PlaybackRecord)? in
                guard let r = progress[item.id], !r.isFinished else { return nil }
                return (item, r)
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .first?.0
        if let inProgress { return inProgress }
        return items.first { item in
            progress[item.id] == nil
        } ?? items.first
    }

    func items(in season: Int) -> [MediaItem] {
        items.filter { ($0.season ?? 1) == season }
             .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }
}

extension SeriesGroup: Hashable {
    static func == (lhs: SeriesGroup, rhs: SeriesGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum LibraryGrouper {
    static func series(from items: [MediaItem], scrapedTitles: [String: String] = [:]) -> [SeriesGroup] {
        let episodes = items.filter { $0.seriesTitle != nil }

        // 第一段：先按"目录推导的剧名"聚合。
        // 这一步保证同一部剧的剧集不会被拆开（哪怕只有部分集刮到了元数据）。
        let rawGroups = Dictionary(grouping: episodes) { item in
            "\(item.sourceID.uuidString)#\(normalize(item.seriesTitle ?? ""))"
        }

        struct Draft {
            var key: String
            var title: String
            var hasScraped: Bool
            var items: [MediaItem]
        }

        var drafts: [Draft] = []
        for (_, list) in rawGroups {
            guard let first = list.first, let raw = first.seriesTitle else { continue }
            let scraped = list.compactMap { scrapedTitles[$0.id] }.first
            let title = scraped ?? displayTitle(raw)
            drafts.append(Draft(key: "\(first.sourceID.uuidString)#\(groupKey(title))",
                                title: title,
                                hasScraped: scraped != nil,
                                items: list))
        }

        // 第二段：按规范化标题合并不同目录（如「H黑镜7（2025）」与「黑镜」）
        let merged = Dictionary(grouping: drafts) { $0.key }
        return merged.compactMap { key, group -> SeriesGroup? in
            guard let head = group.first else { return nil }
            let all = group.flatMap { $0.items }.sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            // 标题优先用刮削到的（更规范）
            let title = group.first(where: { $0.hasScraped })?.title ?? head.title
            return SeriesGroup(id: key, title: title, items: all)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func movies(from items: [MediaItem]) -> [MediaItem] {
        items.filter { $0.seriesTitle == nil }
            .sorted { $0.addedAt > $1.addedAt }
    }

    /// 展示用标题：去掉「（1-6季）」「(2016)」「S01-S06」这类后缀
    static func displayTitle(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)\\s*S\\d{1,2}\\s*[-~]\\s*S?\\d{1,2}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\s.·_-]+$", with: "", options: .regularExpression)
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? s : trimmed
    }

    /// 归并用的键：去掉括号年份、CJK 前的单个字母、结尾季号，让「H黑镜7（2025）」和「黑镜」落到一起
    static func groupKey(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[A-Za-z](?=[\\p{Han}])", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\s.·_-]*\\d{1,3}$", with: "", options: .regularExpression)
        return normalize(t)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
