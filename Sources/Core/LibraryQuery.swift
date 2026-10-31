import Foundation

/// Immutable, cached-only input: querying never starts metadata or network work.
enum LibraryQuery {
    enum State: String, CaseIterable, Identifiable {
        case all, unwatched, watched
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .unwatched: return "未观看"
            case .watched: return "已观看"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case added, title, year, rating
        var id: String { rawValue }
        var label: String {
            switch self {
            case .added: return "添加时间"
            case .title: return "名称"
            case .year: return "年份"
            case .rating: return "评分"
            }
        }
    }

    enum CategoryKind: String, Hashable {
        case years, genres, ratings, certifications

        var title: String {
            switch self {
            case .years: return "年代"
            case .genres: return "类型"
            case .ratings: return "评分"
            case .certifications: return "分级"
            }
        }

        var symbol: String {
            switch self {
            case .years: return "calendar"
            case .genres: return "tag"
            case .ratings: return "star"
            case .certifications: return "checkmark.shield"
            }
        }

        var explanation: String {
            switch self {
            case .years: return "仅按电影首映年份分组，每十年一组。"
            case .genres: return "按已缓存的影视类型浏览。"
            case .ratings: return "评分向下取整分组，例如 7.0–7.9 分归入 7 分。"
            case .certifications: return "按影视分级浏览，同一分级合并展示；适用地区可在详情查看。"
            }
        }
    }
    enum Category: Hashable {
        case decade(Int?)
        case genre(String?)
        case rating(Int?)
        case certification(String?, region: String?)
        var title: String {
            switch self {
            case .decade(let decade): return decade.map(String.init) ?? "未知年代"
            case .genre(let genre): return genre ?? "未知类型"
            case .rating(let rating): return rating.map { "\($0) 分" } ?? "暂无评分"
            case .certification(let value, let region):
                guard let value else { return "暂无分级" }
                return [value, region].compactMap { $0 }.joined(separator: " · ")
            }
        }
    }

    struct CategoryCount: Identifiable {
        let selection: Category
        let count: Int
        var previewIDs: [String] = []
        var id: Category { selection }
    }

    struct Item: Identifiable {
        var id: String
        var title: String
        var searchTerms: [String] = []
        var year: Int?
        var genres: [String] = []
        var rating: Double?
        var certification: String?
        var certificationRegion: String?
        var isSeries = false
        var addedAt: Date
        var isWatched = false
        var isContinuing = false
        var isFavorite = false
        var lastPlayedAt: Date?
    }

    static func results(_ items: [Item], search: String = "", state: State = .all,
                        sort: Sort = .added, category: Category? = nil,
                        recent: Bool = false) -> [Item] {
        let needle = normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        var seen = Set<String>()
        var result = items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            guard state == .all || (state == .watched ? item.isWatched : !item.isWatched) else { return false }
            if !needle.isEmpty,
               !([item.title] + item.searchTerms).contains(where: { normalized($0).contains(needle) }) {
                return false
            }
            switch category {
            case .decade(let decade): return !item.isSeries && decadeStart(item.year) == decade
            case .genre(let genre):
                let genres = cleanGenres(item)
                return genre.map { genres.contains($0) } ?? genres.isEmpty
            case .rating(let rating): return ratingBucket(item.rating) == rating
            case .certification(let value, _):
                return certificationLabel(item.certification) == certificationLabel(value)
            case nil: return true
            }
        }
        if recent { result = Array(result.sorted { precedes($0, $1, sort: .added) }.prefix(60)) }
        return result.sorted { precedes($0, $1, sort: sort) }
    }

    static func recommendations(_ items: [Item], limit: Int = 30) -> [Item] {
        results(items, state: .unwatched).sorted { lhs, rhs in
            if lhs.isContinuing != rhs.isContinuing { return lhs.isContinuing }
            if lhs.isContinuing, lhs.lastPlayedAt != rhs.lastPlayedAt {
                return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
            }
            return precedes(lhs, rhs, sort: .rating)
        }.prefix(max(0, limit)).map { $0 }
    }

    /// 首页轮播的简单推荐：续播优先，其次收藏、未看完、评分与最近添加。
    /// 不发起任何网络请求，只使用已缓存的元数据和播放记录。
    static func carouselRecommendations(_ items: [Item], limit: Int = 8,
                                        now: Date = Date()) -> [Item] {
        let all = results(items)
        guard !all.isEmpty, limit > 0 else { return [] }
        let scored = all.map { item -> (item: Item, score: Double) in
            var score = 0.0
            if item.isContinuing {
                score += 1_000
                if let last = item.lastPlayedAt {
                    score += max(0, 30 - now.timeIntervalSince(last) / 86_400) * 4
                }
            }
            if item.isFavorite { score += 300 }
            if !item.isWatched { score += 150 }
            if let rating = item.rating, rating.isFinite, rating > 0 {
                score += rating * 15
            }
            let age = now.timeIntervalSince(item.addedAt) / 86_400
            score += max(0, 45 - age) * 2
            return (item, score)
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
        }.prefix(limit).map { $0.item }
    }

    static func categories(_ items: [Item], kind: CategoryKind) -> [CategoryCount] {
        var counts: [Category: Int] = [:]
        var previews: [Category: [String]] = [:]
        func append(_ selection: Category, item: Item) {
            counts[selection, default: 0] += 1
            if previews[selection, default: []].count < 3 {
                previews[selection, default: []].append(item.id)
            }
        }
        for item in results(items) {
            switch kind {
            case .years:
                if !item.isSeries { append(.decade(decadeStart(item.year)), item: item) }
            case .genres:
                let genres = cleanGenres(item)
                if genres.isEmpty { append(.genre(nil), item: item) }
                for genre in genres { append(.genre(genre), item: item) }
            case .ratings: append(.rating(ratingBucket(item.rating)), item: item)
            case .certifications: append(certificationCategory(item), item: item)
            }
        }
        return counts.map { CategoryCount(selection: $0.key, count: $0.value,
                                         previewIDs: previews[$0.key] ?? []) }.sorted {
            switch ($0.selection, $1.selection) {
            case (.decade(let lhs), .decade(let rhs)), (.rating(let lhs), .rating(let rhs)):
                return (lhs ?? Int.min) > (rhs ?? Int.min)
            case (.genre(let lhs), .genre(let rhs)):
                if lhs == nil { return false }
                if rhs == nil { return true }
                let l = normalized(lhs!), r = normalized(rhs!)
                return l == r ? lhs! < rhs! : l < r
            case (.certification(let lhs, _), .certification(let rhs, _)):
                if lhs == nil { return false }
                if rhs == nil { return true }
                return $0.selection.title < $1.selection.title
            default: return $0.selection.title < $1.selection.title
            }
        }
    }

    private static func decadeStart(_ year: Int?) -> Int? {
        year.flatMap { $0 > 0 ? ($0 / 10) * 10 : nil }
    }

    private static func ratingBucket(_ rating: Double?) -> Int? {
        rating.flatMap { $0.isFinite && $0 >= 0 && $0 <= 10 ? Int(floor($0)) : nil }
    }

    private static func certificationCategory(_ item: Item) -> Category {
        .certification(certificationLabel(item.certification), region: nil)
    }

    static func certificationLabel(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        // NFO may repeat a classification as "PG-13 / US:Rated PG-13".
        let first = String(value.split(separator: "/").first ?? Substring(value))
        let parts = first.split(separator: ":", maxSplits: 1).map(String.init)
        var label = (parts.last ?? first).trimmingCharacters(in: .whitespacesAndNewlines)
        if label.lowercased().hasPrefix("rated ") { label = String(label.dropFirst(6)) }
        let canonical = ["G", "PG", "PG-13", "R", "NC-17", "NR", "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA"]
        return canonical.contains(label.uppercased()) ? label.uppercased() : (label.isEmpty ? nil : label)
    }

    private static func cleanGenres(_ item: Item) -> Set<String> {
        Set(item.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func precedes(_ lhs: Item, _ rhs: Item, sort: Sort) -> Bool {
        switch sort {
        case .added:
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
        case .title:
            let l = normalized(lhs.title), r = normalized(rhs.title)
            if l != r { return l < r }
        case .year:
            if lhs.year != rhs.year { return (lhs.year ?? Int.min) > (rhs.year ?? Int.min) }
        case .rating:
            let l = lhs.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let r = rhs.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if l != r { return (l ?? -.infinity) > (r ?? -.infinity) }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
        }
        return lhs.id < rhs.id
    }
}
