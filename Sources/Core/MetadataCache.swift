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
    static func invalidateMerged(identity: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.identity == identity || envelope.identity.hasPrefix(identity + "#source#") else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    static func imageIdentity(path: String, sourceID: UUID) -> String {
        path.hasPrefix("http") ? path : "\(sourceID.uuidString)#\(path)"
    }
    static func imageURL(identity: String) -> URL {
        let prefix = identity.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        if let sourceID = UUID(uuidString: prefix) {
            let directory = root.appendingPathComponent("SourceImages/\(sourceID.uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(hash(identity) + ".img")
        }
        return root.appendingPathComponent(hash(identity) + ".img")
    }
    static func invalidateSourceImages(_ sourceID: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("SourceImages/\(sourceID.uuidString)"))
    }
    static func validImage(_ data: Data) -> Bool {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }
    static func validImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return validImage(data)
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
