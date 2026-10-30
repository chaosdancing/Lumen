import Foundation
import CryptoKit
import ImageIO

enum MetadataCache {
    struct Envelope: Codable {
        var schema = 1
        var identity: String
        var sourceFingerprint: String?
        var writtenAt = Date()
        var metadata: MediaMetadata
    }
    static var root: URL {
        let url = StorePaths.root.appendingPathComponent("MetadataCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sourceFingerprint(_ config: MediaSourceConfig) -> String {
        let value = config.normalized()
        // Hash structured fields, including the bookmark that selects a local root.
        let fields = [value.id.uuidString, value.kind.rawValue, value.host, String(value.port),
                      value.basePath, value.username, String(value.usesHTTPS), value.directURL,
                      value.bookmark?.base64EncodedString() ?? ""]
        return hash(String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self))
    }
    static func mergedIdentity(_ identity: String, fingerprint: String) -> String {
        "\(identity)#source#\(fingerprint)"
    }
    /// 精确失效：缓存文件名就是 identity 的哈希，读取方也只按「当前源指纹」拼出的 identity 查找，
    /// 所以只需删掉这两个确定的文件，O(1)，不再遍历 + 解码整个目录（每个条目一次全量扫描）。
    static func invalidateMerged(identity: String, fingerprint: String?) {
        let fm = FileManager.default
        try? fm.removeItem(at: root.appendingPathComponent(hash(identity) + ".json"))
        if let fingerprint {
            try? fm.removeItem(at: root.appendingPathComponent(hash(mergedIdentity(identity, fingerprint: fingerprint)) + ".json"))
        }
    }

    private struct IdentityOnly: Decodable { let identity: String }
    private static let sweepQueue = DispatchQueue(label: "lumen.metadata-cache.sweep", qos: .background)

    /// 后台清理旧源指纹留下的孤儿文件（源配置改过后，旧指纹的记录永远不会再被读到）。
    /// 只删「非当前指纹」的变体，不会与前台刚写入的新缓存竞争；只解码 identity 字段。
    static func sweepStaleMerged(identities: Set<String>, currentFingerprints: Set<String>) {
        guard !identities.isEmpty else { return }
        let root = root
        sweepQueue.async {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: nil) else { return }
            let decoder = JSONDecoder()
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let envelope = try? decoder.decode(IdentityOnly.self, from: data),
                      let range = envelope.identity.range(of: "#source#") else { continue }
                let base = String(envelope.identity[..<range.lowerBound])
                let fingerprint = String(envelope.identity[range.upperBound...])
                guard identities.contains(base), !currentFingerprints.contains(fingerprint) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    static func imageIdentity(path: String, sourceID: UUID) -> String {
        path.hasPrefix("http") ? path : "\(sourceID.uuidString)#\(path)"
    }
    static func imageURL(identity: String) -> URL {
        let prefix = identity.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        if let sourceID = UUID(uuidString: prefix) {
            let directory = root.appendingPathComponent("SourceImages/\(sourceID.uuidString)", isDirectory: true)
            if fileState.markDirectory(directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return directory.appendingPathComponent(hash(identity) + ".img")
        }
        return root.appendingPathComponent(hash(identity) + ".img")
    }
    static func invalidateSourceImages(_ sourceID: UUID) {
        let directory = root.appendingPathComponent("SourceImages/\(sourceID.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        fileState.forgetDirectory(directory.path)
    }
    static func validImage(_ data: Data) -> Bool {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }
    /// UI 渲染路径（封面卡片 body）会高频调用。以前每次都把整张图读进内存再解码一遍；
    /// 现在按 (路径, 修改时间, 大小) 记忆校验结果，命中时只有一次 stat。
    static func validImage(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
            fileState.forgetValidity(url.path)
            return false
        }
        let mtime = attributes[.modificationDate] as? Date ?? .distantPast
        if let cached = fileState.validity(url.path, mtime: mtime, size: size) { return cached }
        guard let data = try? Data(contentsOf: url) else { return false }
        let valid = validImage(data)
        fileState.setValidity(url.path, mtime: mtime, size: size, valid: valid)
        return valid
    }

    private static let fileState = FileStateCache()

    /// 线程安全的小型内存索引：已创建目录 + 图片有效性校验结果。
    private final class FileStateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var directories: Set<String> = []
        private var validity: [String: (mtime: Date, size: Int, valid: Bool)] = [:]

        /// 返回 true 表示第一次见到该目录，需要实际创建
        func markDirectory(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return directories.insert(path).inserted
        }
        func forgetDirectory(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            directories.remove(path)
            validity = validity.filter { !$0.key.hasPrefix(path) }
        }
        func validity(_ path: String, mtime: Date, size: Int) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            guard let hit = validity[path], hit.mtime == mtime, hit.size == size else { return nil }
            return hit.valid
        }
        func setValidity(_ path: String, mtime: Date, size: Int, valid: Bool) {
            lock.lock(); defer { lock.unlock() }
            if validity.count > 4096 { validity.removeAll(keepingCapacity: true) }
            validity[path] = (mtime, size, valid)
        }
        func forgetValidity(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            validity[path] = nil
        }
    }
    static func local(identity: String, sourceConfig: MediaSourceConfig? = nil) -> MediaMetadata? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(hash(identity) + ".json"))
        else { return nil }
        return decode(data, identity: identity, sourceConfig: sourceConfig)?.metadata
    }
    static func decode(_ data: Data, identity: String,
                       sourceConfig: MediaSourceConfig? = nil) -> Envelope? {
        guard let result = try? JSONDecoder().decode(Envelope.self, from: data),
              result.schema == 1, result.identity == identity else { return nil }
        if let sourceConfig {
            guard result.sourceFingerprint == sourceFingerprint(sourceConfig) else { return nil }
        }
        return result
    }
    static func save(_ meta: MediaMetadata, identity: String, source: MediaSource?,
                     shouldCommit: @MainActor () -> Bool = { true }) async throws {
        try Task.checkCancellation()
        guard await shouldCommit() else { throw CancellationError() }
        let data = try JSONEncoder().encode(Envelope(identity: identity,
            sourceFingerprint: source.map { sourceFingerprint($0.config) }, metadata: meta))
        try data.write(to: root.appendingPathComponent(hash(identity) + ".json"), options: .atomic)
        var writeError: Error?
        if let writable = source as? WritableMediaSource {
            // Immutable, content-addressed NAS records: never replace any existing sidecar.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let timestamp = String(format: "%020.0f", Date().timeIntervalSince1970 * 1000)
            do { try await writable.writeCache(data, path: ".lumen-cache/\(hash(identity))--\(timestamp)--\(digest).json") }
            catch { writeError = error }
        }
        try Task.checkCancellation()
        guard await shouldCommit() else { throw CancellationError() }
        if let writeError { throw writeError }
    }
    static func restore(identity: String, source: MediaSource,
                        shouldCommit: @MainActor () -> Bool = { true }) async -> MediaMetadata? {
        guard !Task.isCancelled, await shouldCommit() else { return nil }
        if let hit = local(identity: identity, sourceConfig: source.config) { return hit }
        guard !Task.isCancelled,
              let entries = try? await source.list(path: ".lumen-cache") else { return nil }
        let prefix = hash(identity) + "--"
        var newest: Envelope?
        for entry in entries.filter({ !$0.isDirectory && $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".json") })
            .sorted(by: { $0.name > $1.name }).prefix(64) {
            guard !Task.isCancelled else { return nil }
            guard let data = try? await source.data(for: entry.path),
                  let record = decode(data, identity: identity, sourceConfig: source.config) else { continue }
            if newest == nil || record.writtenAt > newest!.writtenAt { newest = record }
        }
        guard !Task.isCancelled, await shouldCommit(), let newest else { return nil }
        if let data = try? JSONEncoder().encode(newest) {
            try? data.write(to: root.appendingPathComponent(hash(identity) + ".json"), options: .atomic)
        }
        return newest.metadata
    }
}

/// Deduplicates downloads across episodes and persists bytes independently of item IDs.
actor MetadataImageCache {
    static let shared = MetadataImageCache()
    private var requests: [String: Task<Data?, Never>] = [:]
    private var uploaded: Set<String> = []
    private static func valid(_ data: Data) -> Bool {
        MetadataCache.validImage(data)
    }
    func persist(path: String, source: MediaSource, force: Bool = false,
                 shouldCommit: @MainActor () -> Bool = { true }) async throws {
        let identity = MetadataCache.imageIdentity(path: path, sourceID: source.config.id)
        let file = MetadataCache.imageURL(identity: identity)
        var data = force ? nil : try? Data(contentsOf: file)
        if let cached = data, !Self.valid(cached) { data = nil }
        if data == nil {
            let task: Task<Data?, Never>
            if !force, let existing = requests[identity] { task = existing }
            else {
                task = Task {
                    if path.hasPrefix("http"), let url = URL(string: path) {
                        if url.user == nil, url.password == nil,
                           let (bytes, response) = try? await URLSession.shared.data(from: url),
                              let http = response as? HTTPURLResponse,
                           (200..<300).contains(http.statusCode), Self.valid(bytes) { return bytes }
                    } else if let bytes = try? await source.data(for: path), Self.valid(bytes) {
                        return bytes
                    }
                    // Original unavailable: restore the latest immutable image version from NAS.
                    guard let entries = try? await source.list(path: ".lumen-cache") else { return nil }
                    let prefix = MetadataCache.hash(identity) + "--"
                    for entry in entries.filter({ $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".img") })
                        .sorted(by: { $0.name > $1.name }).prefix(16) {
                        if let bytes = try? await source.data(for: entry.path), Self.valid(bytes) { return bytes }
                    }
                    return nil
                }
                if !force { requests[identity] = task }
            }
            data = await task.value
            if !force { requests[identity] = nil }
        }
        try Task.checkCancellation()
        guard await shouldCommit() else { throw CancellationError() }
        guard let data else { return }
        try data.write(to: file, options: .atomic)
        if let writable = source as? WritableMediaSource {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let uploadKey = "\(MetadataCache.sourceFingerprint(source.config))#\(identity)#\(digest)"
            guard !uploaded.contains(uploadKey) else { return }
            let timestamp = String(format: "%020.0f", Date().timeIntervalSince1970 * 1000)
            try await writable.writeCache(data, path: ".lumen-cache/\(MetadataCache.hash(identity))--\(timestamp)--\(digest).img")
            uploaded.insert(uploadKey)
        }
    }
}
