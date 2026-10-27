import Foundation

/// 只基于本地库和已缓存元数据进行查询，不在计算分类时发起网络请求。
enum LibraryQuery {
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
            case .certifications: return "按影视分级浏览，同一分级合并展示。"
            }
        }
    }

    enum Category: Hashable {
        case decade(Int?)
        case genre(String?)
        case rating(Int?)
        case certification(String?)

        var title: String {
            switch self {
            case .decade(let decade): return decade.map(String.init) ?? "未知年代"
            case .genre(let genre): return genre ?? "未知类型"
            case .rating(let rating): return rating.map { "\($0) 分" } ?? "暂无评分"
            case .certification(let value): return value ?? "暂无分级"
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
        var isSeries = false
        var addedAt: Date
        var isWatched = false
        var isContinuing = false
        var lastPlayedAt: Date?
    }

    static func search(_ items: [Item], text: String) -> [Item] {
        let needle = normalized(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return recommendations(items) }
        return results(items).filter { item in
            ([item.title] + item.searchTerms).contains { normalized($0).contains(needle) }
        }.sorted { lhs, rhs in
            let lhsTitle = normalized(lhs.title)
            let rhsTitle = normalized(rhs.title)
            let lhsPrefix = lhsTitle.hasPrefix(needle)
            let rhsPrefix = rhsTitle.hasPrefix(needle)
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            if lhs.rating != rhs.rating { return (lhs.rating ?? 0) > (rhs.rating ?? 0) }
            return lhs.addedAt > rhs.addedAt
        }
    }

    static func recommendations(_ items: [Item], limit: Int = 30) -> [Item] {
        results(items).filter { !$0.isWatched }.sorted { lhs, rhs in
            if lhs.isContinuing != rhs.isContinuing { return lhs.isContinuing }
            if lhs.isContinuing, lhs.lastPlayedAt != rhs.lastPlayedAt {
                return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
            }
            if lhs.rating != rhs.rating { return (lhs.rating ?? 0) > (rhs.rating ?? 0) }
            return lhs.addedAt > rhs.addedAt
        }.prefix(max(0, limit)).map { $0 }
    }

    static func results(_ items: [Item], category: Category? = nil) -> [Item] {
        var seen = Set<String>()
        return items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            switch category {
            case .decade(let decade):
                return !item.isSeries && decadeStart(item.year) == decade
            case .genre(let genre):
                let genres = cleanGenres(item)
                return genre.map { genres.contains($0) } ?? genres.isEmpty
            case .rating(let rating):
                return ratingBucket(item.rating) == rating
            case .certification(let value):
                return certificationLabel(item.certification) == certificationLabel(value)
            case nil:
                return true
            }
        }
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
            case .ratings:
                append(.rating(ratingBucket(item.rating)), item: item)
            case .certifications:
                append(.certification(certificationLabel(item.certification)), item: item)
            }
        }

        return counts.map {
            CategoryCount(selection: $0.key, count: $0.value, previewIDs: previews[$0.key] ?? [])
        }.sorted {
            switch ($0.selection, $1.selection) {
            case (.decade(let lhs), .decade(let rhs)), (.rating(let lhs), .rating(let rhs)):
                return (lhs ?? Int.min) > (rhs ?? Int.min)
            case (.genre(let lhs), .genre(let rhs)):
                if lhs == nil { return false }
                if rhs == nil { return true }
                let l = normalized(lhs!), r = normalized(rhs!)
                return l == r ? lhs! < rhs! : l < r
            case (.certification(let lhs), .certification(let rhs)):
                if lhs == nil { return false }
                if rhs == nil { return true }
                return $0.selection.title < $1.selection.title
            default:
                return $0.selection.title < $1.selection.title
            }
        }
    }

    private static func decadeStart(_ year: Int?) -> Int? {
        year.flatMap { $0 > 0 ? ($0 / 10) * 10 : nil }
    }

    private static func ratingBucket(_ rating: Double?) -> Int? {
        rating.flatMap { $0.isFinite && $0 >= 0 && $0 <= 10 ? Int(floor($0)) : nil }
    }

    static func certificationLabel(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let first = String(value.split(separator: "/").first ?? Substring(value))
        let parts = first.split(separator: ":", maxSplits: 1).map(String.init)
        var label = (parts.last ?? first).trimmingCharacters(in: .whitespacesAndNewlines)
        if label.lowercased().hasPrefix("rated ") { label = String(label.dropFirst(6)) }
        let canonical = ["G", "PG", "PG-13", "R", "NC-17", "NR",
                         "TV-Y", "TV-Y7", "TV-G", "TV-PG", "TV-14", "TV-MA"]
        return canonical.contains(label.uppercased()) ? label.uppercased() : (label.isEmpty ? nil : label)
    }

    private static func cleanGenres(_ item: Item) -> Set<String> {
        Set(item.genres.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
