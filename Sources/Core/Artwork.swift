import Foundation
import AVFoundation
import CryptoKit

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// 封面来源，按优先级回退：
/// 1. 媒体服务器官方海报（Emby/Jellyfin）
/// 2. 同目录的 poster.jpg / folder.jpg / cover.jpg / <同名>.jpg
/// 3. 本地视频抽帧（远程源抽帧要拉大段数据，先不做）
/// 4. nil → UI 用渐变占位
@MainActor
final class ArtworkStore: ObservableObject {
    /// 解析规则版本：改了封面查找逻辑就 +1，旧缓存自动失效
    /// （曾经因为规则升级后仍命中旧缓存，导致单集封面一直是同一张）
    private static let cacheVersion = "v4"

    private var memory: [String: PlatformImage] = [:]

    private var cacheDir: URL {
        let dir = StorePaths.root.appendingPathComponent("Caches/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cached(_ itemID: String, variant: ArtworkVariant = .poster,
                revision: Int = 0) -> PlatformImage? {
        memory[cacheKey(itemID: itemID, variant: variant, revision: revision)]
    }

    func requestIdentity(for item: MediaItem, variant: ArtworkVariant = .poster,
                         in store: AppStore) -> String {
        let metadata = MetadataStore.shared.artworkMetadata(for: item)
        let config = store.source(for: item.sourceID)
        let fingerprint = config.map(MetadataCache.sourceFingerprint) ?? ""
        let posterSource = metadata?.fieldSources?["posterPath"] ?? metadata?.source ?? ""
        let backdropSource = metadata?.fieldSources?["backdropPath"] ?? metadata?.source ?? ""
        let serverPoster = store.posterURL(for: item)?.absoluteString ?? ""
        let fields: [String] = [fingerprint,
                      metadata?.posterPath ?? "", metadata?.backdropPath ?? "",
                      posterSource, backdropSource, serverPoster,
                      metadata?.artworkRefreshID ?? "",
                      TMDBClient.language, String(Preferences.shared.preferNFO)]
        let resolved = MetadataCache.hash(String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self))
        return cacheKey(itemID: item.id, variant: variant, revision: store.artworkRevision) + "#\(resolved)"
    }

    func cached(for item: MediaItem, variant: ArtworkVariant = .poster,
                in store: AppStore) -> PlatformImage? {
        memory[requestIdentity(for: item, variant: variant, in: store)]
    }

    func image(for item: MediaItem, variant: ArtworkVariant = .poster,
               in store: AppStore) async -> PlatformImage? {
        let requestRevision = store.artworkRevision
        let requestSource = store.source(for: item.sourceID)
        guard !Task.isCancelled, requestSource != nil else { return nil }
        let key = requestIdentity(for: item, variant: variant, in: store)
        if let hit = memory[key] { return hit }

        let file = cacheDir.appendingPathComponent(Self.hash(key) + ".img")
        let useDiskCache = (variant != .thumb)   // 缩略图不落盘，避免旧规则缓存一直生效
        if useDiskCache, let data = try? Data(contentsOf: file), let img = PlatformImage(data: data) {
            memory[key] = img
            return img
        } else if useDiskCache {
            try? FileManager.default.removeItem(at: file)
        }

        func accept(_ data: Data?) -> PlatformImage? {
            guard !Task.isCancelled, requestRevision == store.artworkRevision,
                  requestSource == store.source(for: item.sourceID),
                  key == requestIdentity(for: item, variant: variant, in: store) else { return nil }
            guard let data, let image = PlatformImage(data: data) else { return nil }
            memory[key] = image
            if useDiskCache { try? data.write(to: file, options: .atomic) }
            return image
        }

        func localData() async -> Data? {
            guard let path = await LocalArtworkResolver.shared.path(for: item, variant: variant,
                                                                     in: store) else { return nil }
            let sharedFile = MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: path, sourceID: item.sourceID))
            if let data = try? Data(contentsOf: sharedFile), PlatformImage(data: data) != nil { return data }
            guard let data = try? await store.data(for: item, path: path),
                  !Task.isCancelled, requestRevision == store.artworkRevision,
                  requestSource == store.source(for: item.sourceID),
                  key == requestIdentity(for: item, variant: variant, in: store) else { return nil }
            if PlatformImage(data: data) != nil { try? data.write(to: sharedFile, options: .atomic) }
            return data
        }

        func metadataData(path: String?, url: URL?) async -> Data? {
            if let url, url.isFileURL { return try? Data(contentsOf: url) }
            if let metadata = MetadataStore.shared.artworkMetadata(for: item),
               (metadata.fieldSources?[variant == .backdrop ? "backdropPath" : "posterPath"] == "nfo"
                || (metadata.fieldSources == nil && metadata.source == "nfo")),
               let path, !path.hasPrefix("http") {
                return try? await store.data(for: item, path: path)
            }
            guard let url else { return nil }
            return try? await Self.fetch(url)
        }

        let preferLocal = Preferences.shared.preferLocalPoster
        let metadata = MetadataStore.shared.artworkMetadata(for: item)

        // 本地偏好只改变顺序；每份字节都先解码，坏图不会阻塞后续来源。
        if preferLocal, let image = accept(await localData()) {
            return image
        }

        switch variant {
        case .poster:
            if let url = store.posterURL(for: item),
               let image = accept(try? await Self.fetch(url)) {
                return image
            }
            if let image = accept(await metadataData(
                path: metadata?.posterPath,
                url: MetadataStore.shared.cachedPosterURL(for: item)
            )) {
                return image
            }
        case .backdrop:
            if let image = accept(await metadataData(
                path: metadata?.backdropPath,
                url: MetadataStore.shared.backdropURL(for: item)
            )) {
                return image
            }
        case .thumb:
            if let image = accept(await metadataData(
                path: metadata?.posterPath,
                url: MetadataStore.shared.cachedPosterURL(for: item)
            )) {
                return image
            }
        }

        if !preferLocal, let image = accept(await localData()) {
            return image
        }

        // 横版图的所有来源都失败后再退回竖版海报。
        if variant == .backdrop {
            return await image(for: item, variant: .poster, in: store)
        }

        if store.source(for: item.sourceID)?.kind == .local,
           let image = accept(await frameThumbnail(for: item, in: store)) {
            return image
        }

        return nil
    }

    private func cacheKey(itemID: String, variant: ArtworkVariant, revision: Int) -> String {
        let preference = Preferences.shared.preferLocalPoster ? "local" : "remote"
        return "\(Self.cacheVersion)#\(itemID)#\(variantKey(variant))#\(preference)#r\(revision)"
    }

    private func variantKey(_ v: ArtworkVariant) -> String {
        switch v {
        case .poster:   return "p"
        case .backdrop: return "b"
        case .thumb:    return "t"
        }
    }

    /// 列表刷新（重新扫描）后清掉失败记录，允许重试
    func resetFailures() {}

    // MARK: - 具体来源

    private func sidecarImageData(for item: MediaItem, in store: AppStore) async -> Data? {
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config) else { return nil }
        let dir = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidates = ["poster.jpg", "folder.jpg", "cover.jpg", "\(stem).jpg", "\(stem).png"]

        guard let entries = try? await source.list(path: dir) else { return nil }
        let names = Set(entries.filter { !$0.isDirectory }.map { $0.name.lowercased() })
        for candidate in candidates where names.contains(candidate.lowercased()) {
            let path = dir.isEmpty ? candidate : "\(dir)/\(candidate)"
            if let data = try? await source.data(for: path) { return data }
        }
        return nil
    }

    private func frameThumbnail(for item: MediaItem, in store: AppStore) async -> Data? {
        guard let config = store.source(for: item.sourceID),
              let source = try? MediaSourceFactory.make(config),
              let url = try? await source.playURL(for: item.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 720)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 8, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 8, preferredTimescale: 600)

        // 取 10% 处的帧，避开片头黑场
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: max(1, duration * 0.1), preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }

        #if os(macOS)
        let image = NSImage(cgImage: cg, size: .zero)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #else
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
        #endif
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession(configuration: .default,
                                                    delegate: LocalNetworkTrustDelegate.shared,
                                                    delegateQueue: nil).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.badResponse(http.statusCode)
        }
        return data
    }

    private static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
