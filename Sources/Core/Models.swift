import Foundation

// MARK: - 源

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case local, webdav, smb, http, emby, jellyfin
    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:    return "本地文件夹"
        case .webdav:   return "WebDAV"
        case .smb:      return "SMB"
        case .http:     return "在线直链"
        case .emby:     return "Emby"
        case .jellyfin: return "Jellyfin"
        }
    }

    var symbol: String {
        switch self {
        case .local:    return "folder"
        case .webdav:   return "externaldrive.connected.to.line.below"
        case .smb:      return "server.rack"
        case .http:     return "link"
        case .emby:     return "play.tv"
        case .jellyfin: return "play.tv.fill"
        }
    }

    /// 是否为媒体服务器（走目录式扫描以外的 catalog 路径）
    var isMediaServer: Bool {
        switch self {
        case .emby, .jellyfin: return true
        default: return false
        }
    }

    /// 当前里程碑是否已实现
    var isAvailable: Bool {
        switch self {
        case .local, .webdav, .http, .emby, .jellyfin: return true
        case .smb: return false
        }
    }
}

struct MediaSourceConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: SourceKind
    var name: String
    var host: String = ""
    var port: Int = 0
    var basePath: String = "/"
    var username: String = ""
    var usesHTTPS: Bool = true
    /// 本地目录的安全作用域书签
    var bookmark: Data? = nil
    /// 仅在内存中使用，不落盘（密码走 Keychain）
    var password: String = ""
    var directURL: String = ""

    /// 用户可能把整条 URL 粘进"主机"字段，这里统一拆成 host / port / basePath
    func normalized() -> MediaSourceConfig {
        var copy = self
        let raw = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return copy }

        // 用 URLComponents 解析，而不是手拆冒号：带 `http://` 粘贴进主机栏时，
        // 不能让 URL 的默认 80 覆盖用户在端口栏明确填写的 5005。
        let hasScheme = raw.range(of: "://") != nil
        let parseInput = hasScheme ? raw : "\(copy.usesHTTPS ? "https" : "http")://\(raw)"
        guard let components = URLComponents(string: parseInput),
              let parsedHost = components.host, !parsedHost.isEmpty else {
            return copy
        }
        if hasScheme, let scheme = components.scheme?.lowercased() {
            if scheme == "https" { copy.usesHTTPS = true }
            if scheme == "http" { copy.usesHTTPS = false }
        }
        copy.host = parsedHost

        // 端口栏是显式配置，优先级高于粘贴 URL；只有它为空时才取 URL 内端口。
        if copy.port == 0, let parsedPort = components.port {
            copy.port = parsedPort
        }
        let parsedPath = components.percentEncodedPath.removingPercentEncoding
            ?? components.percentEncodedPath
        if !parsedPath.isEmpty, parsedPath != "/", copy.basePath == "/" || copy.basePath.isEmpty {
            copy.basePath = parsedPath
        }

        // 端口留空时按 scheme 兜底
        if copy.port == 0 {
            copy.port = copy.usesHTTPS ? 443 : 80
        }
        if copy.basePath.isEmpty { copy.basePath = "/" }
        return copy
    }

    var subtitle: String {
        switch kind {
        case .local:  return basePath
        case .webdav, .smb, .emby, .jellyfin:
            let scheme = usesHTTPS ? "https" : "http"
            let p = port == 0 ? "" : ":\(port)"
            return "\(scheme)://\(host)\(p)\(basePath)"
        case .http: return directURL
        }
    }
}

// MARK: - 媒体条目

enum MediaKind: String, Codable {
    case movie, episode
}

struct MediaItem: Identifiable, Codable, Hashable {
    var id: String
    var sourceID: UUID
    /// 源内的相对路径
    var path: String
    var fileName: String
    var title: String
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
    var year: Int?
    var size: Int64?
    var addedAt: Date = Date()
    /// 媒体服务器上的条目 ID（Emby/Jellyfin/Plex），用于取流与海报
    var remoteID: String?

    var kind: MediaKind { seriesTitle == nil ? .movie : .episode }

    var displaySubtitle: String? {
        if let s = season, let e = episode {
            return String(format: "S%02dE%02d", s, e)
        }
        if let y = year { return String(y) }
        return nil
    }
}

// MARK: - 播放进度

struct PlaybackRecord: Codable, Hashable {
    var itemID: String
    var position: Double
    var duration: Double
    var updatedAt: Date

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
    var isFinished: Bool { progress > 0.95 }
    var isInProgress: Bool { position >= 5 && !isFinished }
}

// MARK: - 远程目录项

struct RemoteEntry: Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64?
}

enum SourceError: LocalizedError {
    case notImplemented(String)
    case unauthorized
    case badResponse(Int)
    case missingBookmark
    case invalidURL
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let s): return "\(s) 尚未实现（见路线图）"
        case .unauthorized:          return "认证失败，请检查账号密码"
        case .badResponse(let c):    return "服务端返回 \(c)"
        case .missingBookmark:       return "该文件夹未授权，请重新添加"
        case .invalidURL:            return "地址无效"
        case .invalidResponse(let s): return "服务端响应无效：\(s)"
        }
    }
}

// MARK: - 视频扩展名

enum MediaFileType {
    static let video: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm",
        "ts", "m2ts", "mpg", "mpeg", "rmvb", "rm", "iso", "strm", "m3u8"
    ]
    static let subtitle: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup"]
    /// 封面图 / 背景图（Emby、Jellyfin、Kodi 的 -poster/-fanart/-thumb）
    static let image: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "gif"]
    /// 元数据文件
    static let metadata: Set<String> = ["nfo"]

    static func isVideo(_ name: String) -> Bool {
        video.contains((name as NSString).pathExtension.lowercased())
    }

    static func isImage(_ name: String) -> Bool {
        image.contains((name as NSString).pathExtension.lowercased())
    }

    /// 列目录时需要保留的附属文件（封面、字幕、nfo）
    static func isSidecar(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return subtitle.contains(ext) || image.contains(ext) || metadata.contains(ext)
    }
}
