import Foundation

/// 封面种类
enum ArtworkVariant {
    case poster     // 2:3 竖版
    case backdrop   // 16:9 横版（详情页 hero）
    case thumb      // 剧集缩略图
}

/// 纯匹配逻辑：给定一个目录里的文件名，挑出对应规格的图片。
///
/// 覆盖 Emby / Jellyfin / Kodi / tinyMediaManager 的命名：
///   `<stem>-poster.jpg` / `<stem>-fanart.jpg` / `<stem>-landscape.png` / `<stem>-thumb.jpg`
///   `poster.jpg` / `folder.jpg` / `cover.jpg` / `fanart.jpg` / `backdrop.jpg` / `thumb.jpg`
///   `season01-poster.jpg`
enum ArtworkMatcher {

    static func match(names: [String], stem: String, variant: ArtworkVariant,
                      season: Int? = nil) -> String? {
        var candidates: [String] = []
        switch variant {
        case .poster:
            candidates = [
                "\(stem)-poster.jpg", "\(stem)-poster.png", "\(stem)-poster.jpeg",
                "\(stem).jpg", "\(stem).png",
                "poster.jpg", "poster.png", "folder.jpg", "folder.png", "cover.jpg", "cover.png"
            ]
        case .backdrop:
            candidates = [
                "\(stem)-fanart.jpg", "\(stem)-fanart.png",
                "\(stem)-landscape.png", "\(stem)-landscape.jpg",
                "\(stem)-backdrop.jpg", "\(stem)-backdrop.png",
                "\(stem)-background.jpg",
                "fanart.jpg", "fanart.png", "backdrop.jpg", "backdrop.png", "background.jpg"
            ]
        case .thumb:
            candidates = [
                "\(stem)-thumb.jpg", "\(stem)-thumb.png", "\(stem)-thumb.jpeg",
                "\(stem)-landscape.jpg",
                "thumb.jpg", "thumb.png"
            ]
        }

        // 剧集根目录里可能是 seasonNN-poster.jpg
        if let season, variant == .poster {
            candidates.insert(String(format: "season%02d-poster.jpg", season), at: 0)
            candidates.insert(String(format: "season%d-poster.jpg", season), at: 1)
        }

        let lower = Set(names.map { $0.lowercased() })
        for candidate in candidates where lower.contains(candidate.lowercased()) {
            return names.first { $0.lowercased() == candidate.lowercased() } ?? candidate
        }
        return nil
    }

    /// 从 `S01` / `Season 1` 里取季号
    static func seasonNumber(fromDirectoryName name: String) -> Int? {
        if let m = name.range(of: "(?i)^s(\\d{1,2})$", options: .regularExpression) {
            return Int(name[m].dropFirst())
        }
        if let m = name.range(of: "(?i)season[ ._-]?(\\d{1,2})", options: .regularExpression) {
            return Int(name[m].filter(\.isNumber))
        }
        return nil
    }
}
