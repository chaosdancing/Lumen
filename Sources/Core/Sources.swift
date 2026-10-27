import Foundation

/// 所有存储后端收敛成这一个协议。新增一种源 = 新增一个实现，UI 与扫描器不用改。
protocol MediaSource: AnyObject, Sendable {
    var config: MediaSourceConfig { get }
    /// 列出某个目录下的直接子项
    func list(path: String) async throws -> [RemoteEntry]
    /// 把源内路径解析成可播放的 URL
    func playURL(for path: String) async throws -> URL
    /// 读取一个文件的原始字节（用于加载同目录字幕）
    func data(for path: String) async throws -> Data
    /// 播放时需要附带的 HTTP 头（WebDAV 的 Basic 认证等）
    func playbackHeaders() -> [String: String]
}

extension MediaSource {
    func playbackHeaders() -> [String: String] { [:] }
}

/// 播放目标：URL + 需要的请求头
struct PlaybackTarget {
    var url: URL
    var headers: [String: String]
    /// 保持本地安全作用域在整个播放期间有效。
    var accessLease: (any MediaSource)? = nil
}

// MARK: - 本地目录

final class LocalMediaSource: MediaSource, @unchecked Sendable {
    let config: MediaSourceConfig
    private let root: URL
    private var needsScope = true

    init(config: MediaSourceConfig) throws {
        self.config = config
        // 没有书签时，允许直接使用绝对路径（应用容器内的目录不需要授权）
        guard let data = config.bookmark else {
            let url = URL(fileURLWithPath: config.basePath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw SourceError.missingBookmark
            }
            self.root = url
            self.needsScope = false
            return
        }
        var stale = false
        #if os(macOS)
        let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let resolveOptions: URL.BookmarkResolutionOptions = []
        #endif
        let url = try URL(resolvingBookmarkData: data,
                          options: resolveOptions,
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        self.root = url
        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed || FileManager.default.isReadableFile(atPath: url.path) else {
            throw SourceError.missingBookmark
        }
        self.needsScope = accessed
    }

    deinit { if needsScope { root.stopAccessingSecurityScopedResource() } }

    func list(path: String) async throws -> [RemoteEntry] {
        let dir = path.isEmpty ? root : root.appendingPathComponent(path)
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let name = url.lastPathComponent
            if !isDir && !MediaFileType.isVideo(name) && !MediaFileType.isSidecar(name) {
                return nil
            }
            return RemoteEntry(name: name,
                               path: path.isEmpty ? name : "\(path)/\(name)",
                               isDirectory: isDir,
                               size: values?.fileSize.map(Int64.init))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
    }

    func playURL(for path: String) async throws -> URL {
        root.appendingPathComponent(path)
    }

    func data(for path: String) async throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }
}

// MARK: - 局域网自签证书
/// NAS 多半是自签证书。只对私有网段（10/8、172.16/12、192.168/16、127、.local）放宽，
/// 公网域名仍走系统默认校验。
final class LocalNetworkTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = LocalNetworkTrustDelegate()

    private func isPrivate(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch parts[0] {
        case 10, 127: return true
        case 192:     return parts[1] == 168
        case 172:     return (16...31).contains(parts[1])
        default:      return false
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isPrivate(challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - HTTP/HTTPS 直链

final class DirectMediaSource: CatalogSource, @unchecked Sendable {
    let config: MediaSourceConfig

    init(config: MediaSourceConfig) { self.config = config }

    private var url: URL? {
        guard let url = URL(string: config.directURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    func fetchCatalog() async throws -> [MediaItem] {
        guard let url else { throw SourceError.invalidURL }
        let fileName = url.lastPathComponent.isEmpty ? config.name : url.lastPathComponent
        return [MediaItem(id: "\(config.id.uuidString)#\(url.absoluteString)",
                          sourceID: config.id, path: url.absoluteString,
                          fileName: fileName, title: config.name,
                          seriesTitle: nil, season: nil, episode: nil,
                          year: nil, size: nil)]
    }

    func list(path: String) async throws -> [RemoteEntry] { [] }
    func playURL(for path: String) async throws -> URL {
        guard let url else { throw SourceError.invalidURL }
        return url
    }
    func data(for path: String) async throws -> Data {
        throw SourceError.notImplemented("直链附属文件")
    }
}

// MARK: - WebDAV

/// 限制并发请求数：封面会同时发几十个 PROPFIND，NAS 扛不住（iPad 上实测 149 次失败）
actor RequestGate {
    static let shared = RequestGate(limit: 4)
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

final class WebDAVMediaSource: MediaSource, @unchecked Sendable {
    let config: MediaSourceConfig
    private let session: URLSession
    private let rootURL: URL

    init(config: MediaSourceConfig) throws {
        self.config = config
        let scheme = config.usesHTTPS ? "https" : "http"
        let port = config.port == 0 ? "" : ":\(config.port)"
        let raw = "\(scheme)://\(config.host)\(port)\(config.basePath.hasPrefix("/") ? "" : "/")\(config.basePath)"
        guard let url = URL(string: raw) else { throw SourceError.invalidURL }
        self.rootURL = url

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg,
                                  delegate: LocalNetworkTrustDelegate.shared,
                                  delegateQueue: nil)
    }

    private var authHeader: String? {
        guard !config.username.isEmpty else { return nil }
        let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }

    func playbackHeaders() -> [String: String] {
        guard let authHeader else { return [:] }
        return ["Authorization": authHeader]
    }

    private func authorize(_ request: inout URLRequest) {
        guard !config.username.isEmpty else { return }
        let pair = "\(config.username):\(config.password)"
        let token = Data(pair.utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    func list(path: String) async throws -> [RemoteEntry] {
        var url = rootURL
        if !path.isEmpty {
            for comp in path.split(separator: "/") {
                url.appendPathComponent(String(comp))
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
          <d:resourcetype/><d:getcontentlength/><d:displayname/>
        </d:prop></d:propfind>
        """.data(using: .utf8)
        authorize(&request)

        await RequestGate.shared.acquire()
        var result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            // 并发过高时偶发失败，退避后重试一次
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                result = try await session.data(for: request)
            } catch {
                await RequestGate.shared.release()
                throw error
            }
            await RequestGate.shared.release()
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse(0) }
            if http.statusCode == 401 { throw SourceError.unauthorized }
            guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
                throw SourceError.badResponse(http.statusCode)
            }
            return WebDAVResponseParser.parse(data, directoryPath: url.path, relativeTo: path)
        }
        await RequestGate.shared.release()
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw SourceError.badResponse(0) }
        if http.statusCode == 401 { throw SourceError.unauthorized }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
            throw SourceError.badResponse(http.statusCode)
        }
        return WebDAVResponseParser.parse(data, directoryPath: url.path, relativeTo: path)
    }

    func playURL(for path: String) async throws -> URL {
        var url = rootURL
        for comp in path.split(separator: "/") { url.appendPathComponent(String(comp)) }
        return url
    }

    func data(for path: String) async throws -> Data {
        var url = rootURL
        for comp in path.split(separator: "/") { url.appendPathComponent(String(comp)) }
        var request = URLRequest(url: url)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badResponse(http.statusCode)
        }
        return data
    }
}

/// PROPFIND 响应解析：只取 href / resourcetype / getcontentlength
///
/// 关键点：判断"是不是目录自身"必须比对**绝对路径**，不能用 hasSuffix(相对路径) ——
/// 根目录时相对路径是空串，`hasSuffix("")` 恒为 true，会把所有条目都过滤掉（这个 bug 真踩过）。
final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private struct Node { var href = ""; var isCollection = false; var length: Int64?; var text = "" }
    private var nodes: [Node] = []
    private var current: Node?
    private var stack: [String] = []

    /// - Parameters:
    ///   - directoryPath: 当前请求目录的绝对路径，例如 `/video/movies`
    ///   - relativeTo: 该目录相对于源根的路径，例如 `""` 或 `剧集/第一季`
    static func parse(_ data: Data, directoryPath: String, relativeTo: String) -> [RemoteEntry] {
        let p = WebDAVResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()

        let dir = normalize(directoryPath)
        var result: [RemoteEntry] = []

        for node in p.nodes {
            guard let hrefPath = pathComponent(of: node.href) else { continue }
            let normalized = normalize(hrefPath)
            // 跳过目录自身
            if normalized == dir { continue }
            // 只处理直接子项（Depth:1 本身只返回直接子项，这里再兜一层）
            guard normalized.hasPrefix(dir == "/" ? "/" : dir + "/") else { continue }

            var rel = String(normalized.dropFirst(dir == "/" ? 1 : dir.count + 1))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }

            let name = (rel as NSString).lastPathComponent
            guard !name.isEmpty else { continue }

            if !node.isCollection,
               !MediaFileType.isVideo(name),
               !MediaFileType.isSidecar(name) {
                continue
            }

            let childPath = relativeTo.isEmpty ? rel : "\(relativeTo)/\(rel)"
            result.append(RemoteEntry(name: name,
                                      path: childPath,
                                      isDirectory: node.isCollection,
                                      size: node.length))
        }

        return result.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
    }

    /// href 可能是绝对 URL（http://host/a/b）也可能是路径（/a/b），统一取出路径部分并解码
    private static func pathComponent(of href: String) -> String? {
        var raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http"), let u = URL(string: raw) {
            raw = u.path
        }
        if let decoded = raw.removingPercentEncoding { raw = decoded }
        return raw.isEmpty ? nil : raw
    }

    /// 去掉末尾斜杠（保留根 "/"）
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "/" : p
    }

    /// 群晖返回 <D:response>，XMLParser 默认不做命名空间处理，
    /// elementName 会带上 "D:" 前缀 —— 必须剥掉，否则一个节点都匹配不上。
    private static func localName(_ element: String, _ qName: String?) -> String {
        let raw = qName ?? element
        let local = raw.split(separator: ":").last.map(String.init) ?? raw
        return local.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = Self.localName(elementName, qName)
        stack.append(name)
        if name == "response" { current = Node() }
        if name == "collection", current != nil { current?.isCollection = true }
        current?.text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.localName(elementName, qName)
        defer { if !stack.isEmpty { stack.removeLast() } }
        guard var node = current else { return }
        switch name {
        case "href":              node.href = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getcontentlength":  node.length = Int64(node.text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "response":
            nodes.append(node)
            current = nil
            return
        default: break
        }
        current = node
    }
}

// MARK: - SMB（里程碑 2：接 AMSMB2）

final class SMBMediaSource: MediaSource, @unchecked Sendable {
    let config: MediaSourceConfig
    init(config: MediaSourceConfig) { self.config = config }

    func list(path: String) async throws -> [RemoteEntry] {
        throw SourceError.notImplemented("SMB（计划用 AMSMB2 接入）")
    }
    func playURL(for path: String) async throws -> URL {
        throw SourceError.notImplemented("SMB 直链（需要本地 HTTP 中转）")
    }
    func data(for path: String) async throws -> Data {
        throw SourceError.notImplemented("SMB 读取")
    }
}

// MARK: - 工厂

enum MediaSourceFactory {
    static func make(_ rawConfig: MediaSourceConfig) throws -> MediaSource {
        let config = rawConfig.normalized()
        switch config.kind {
        case .local:  return try LocalMediaSource(config: config)
        case .webdav: return try WebDAVMediaSource(config: config)
        case .smb:    return SMBMediaSource(config: config)
        case .http:   return DirectMediaSource(config: config)
        case .emby, .jellyfin: return try MediaServerSource(config: config)
        }
    }
}
