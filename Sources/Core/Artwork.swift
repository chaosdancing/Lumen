import Foundation
import AVFoundation
import CryptoKit
import ImageIO

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

    /// 有上限的内存缓存。以前是普通字典且保存原图（TMDB w1280 背景解码后约 3.6 MB/张），
    /// 浏览完整个媒体库内存会无限增长；NSCache 以「解码后像素字节数」为 cost，
    /// 超限或收到内存警告时自动淘汰。
    private let memory: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        #if os(macOS)
        cache.totalCostLimit = 256 * 1024 * 1024
        #else
        cache.totalCostLimit = 128 * 1024 * 1024
        #endif
        cache.countLimit = 600
        return cache
    }()
    /// artworkRevision 变化（重新扫描/改源）时整体清空，旧 revision 的图不再占内存
    private var memoryRevision = -1

    /// requestIdentity 的记忆化：原实现每次 body 渲染都对每张卡片做 JSONEncoder + SHA256
    /// 并构造 MediaServerSource。输入只随下列版本号变化，按 (item, variant) 缓存即可。
    private struct IdentityStamp: Equatable {
        let artworkRevision: Int
        let metadataRevision: UInt64
        let language: String
        let preferNFO: Bool
        let preferLocal: Bool
    }
    private var identityMemo: [String: (stamp: IdentityStamp, identity: String)] = [:]

    private let cacheDir: URL = {
        let dir = StorePaths.root.appendingPathComponent("Caches/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 共享 session：以前每次 fetch 都新建带 delegate 的 URLSession 且不 invalidate，会持续泄漏
    private static let session = URLSession(configuration: .default,
                                            delegate: LocalNetworkTrustDelegate.shared,
                                            delegateQueue: nil)

    private func syncRevision(_ revision: Int) {
        guard revision != memoryRevision else { return }
        memoryRevision = revision
        memory.removeAllObjects()
        identityMemo.removeAll(keepingCapacity: true)
    }

    private func memoryImage(_ key: String) -> PlatformImage? {
        memory.object(forKey: key as NSString)
    }

    private func storeMemory(_ image: PlatformImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: ArtworkDecoder.cost(of: image))
    }

    func cached(_ itemID: String, variant: ArtworkVariant = .poster,
                revision: Int = 0) -> PlatformImage? {
        memoryImage(cacheKey(itemID: itemID, variant: variant, revision: revision))
    }

    func requestIdentity(for item: MediaItem, variant: ArtworkVariant = .poster,
                         in store: AppStore) -> String {
        syncRevision(store.artworkRevision)
        let stamp = IdentityStamp(artworkRevision: store.artworkRevision,
                                  metadataRevision: MetadataStore.shared.revision,
                                  language: TMDBClient.language,
                                  preferNFO: Preferences.shared.preferNFO,
                                  preferLocal: Preferences.shared.preferLocalPoster)
        let memoKey = "\(item.id)#\(variantKey(variant))"
        if let hit = identityMemo[memoKey], hit.stamp == stamp { return hit.identity }

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
        let resolved = Self.hash(fields.joined(separator: "\u{1}"))
        let identity = cacheKey(itemID: item.id, variant: variant, revision: store.artworkRevision) + "#\(resolved)"
        if identityMemo.count > 8192 { identityMemo.removeAll(keepingCapacity: true) }
        identityMemo[memoKey] = (stamp, identity)
        return identity
    }

    func cached(for item: MediaItem, variant: ArtworkVariant = .poster,
                in store: AppStore) -> PlatformImage? {
        memoryImage(requestIdentity(for: item, variant: variant, in: store))
    }

    func image(for item: MediaItem, variant: ArtworkVariant = .poster,
               in store: AppStore) async -> PlatformImage? {
        let requestRevision = store.artworkRevision
        let requestSource = store.source(for: item.sourceID)
        guard !Task.isCancelled, requestSource != nil else { return nil }
        let key = requestIdentity(for: item, variant: variant, in: store)
        if let hit = memoryImage(key) { return hit }

        let file = cacheDir.appendingPathComponent(Self.hash(key) + ".img")
        let useDiskCache = (variant != .thumb)   // 缩略图不落盘，避免旧规则缓存一直生效
        let maxPixel = ArtworkDecoder.maxPixel(for: variant)
        if useDiskCache {
            // 读盘 + 降采样解码放到后台，主线程只拿最终位图
            if let img = await ArtworkDecoder.decodeFile(file, maxPixel: maxPixel) {
                guard !Task.isCancelled else { return nil }
                storeMemory(img, key: key)
                return img
            }
        }

        func accept(_ data: Data?) async -> PlatformImage? {
            guard let data, !Task.isCancelled else { return nil }
            // 解码一次（降采样）同时完成有效性校验；不再「先 PlatformImage(data:) 校验、再解码」
            guard let image = await ArtworkDecoder.decode(data, maxPixel: maxPixel) else { return nil }
            guard !Task.isCancelled, requestRevision == store.artworkRevision,
                  requestSource == store.source(for: item.sourceID),
                  key == requestIdentity(for: item, variant: variant, in: store) else { return nil }
            storeMemory(image, key: key)
            if useDiskCache { ArtworkDecoder.write(data, to: file) }
            return image
        }

        func localData() async -> Data? {
            guard let path = await LocalArtworkResolver.shared.path(for: item, variant: variant,
                                                                     in: store) else { return nil }
            let sharedFile = MetadataCache.imageURL(identity: MetadataCache.imageIdentity(path: path, sourceID: item.sourceID))
            // validImage(at:) 带 (mtime,size) 记忆化，命中时只 stat 一次
            if MetadataCache.validImage(at: sharedFile), let data = await ArtworkDecoder.read(sharedFile) {
                return data
            }
            guard let data = try? await store.data(for: item, path: path),
                  !Task.isCancelled, requestRevision == store.artworkRevision,
                  requestSource == store.source(for: item.sourceID),
                  key == requestIdentity(for: item, variant: variant, in: store) else { return nil }
            // 写共享缓存前不再整图解码校验：坏图会在 accept 解码时被拒，validImage(at:) 也会识别
            ArtworkDecoder.write(data, to: sharedFile)
            return data
        }

        func metadataData(path: String?, url: URL?) async -> Data? {
            if let url, url.isFileURL { return await ArtworkDecoder.read(url) }
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
        if preferLocal, let image = await accept(await localData()) {
            return image
        }

        switch variant {
        case .poster:
            if let url = store.posterURL(for: item),
               let image = await accept(try? await Self.fetch(url)) {
                return image
            }
            if let image = await accept(await metadataData(
                path: metadata?.posterPath,
                url: MetadataStore.shared.cachedPosterURL(for: item)
            )) {
                return image
            }
        case .backdrop:
            if let image = await accept(await metadataData(
                path: metadata?.backdropPath,
                url: MetadataStore.shared.backdropURL(for: item)
            )) {
                return image
            }
        case .thumb:
            if let image = await accept(await metadataData(
                path: metadata?.posterPath,
                url: MetadataStore.shared.cachedPosterURL(for: item)
            )) {
                return image
            }
        }

        if !preferLocal, let image = await accept(await localData()) {
            return image
        }

        // 横版图的所有来源都失败后再退回竖版海报。
        if variant == .backdrop {
            return await image(for: item, variant: .poster, in: store)
        }

        if store.source(for: item.sourceID)?.kind == .local,
           let image = await accept(await frameThumbnail(for: item, in: store)) {
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
        let (data, response) = try await session.data(for: request)
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

// MARK: - 后台解码

/// 读盘与解码都在后台执行，并按显示尺寸降采样：
/// 海报卡片最大显示约 190pt × 3x ≈ 570px，原图 TMDB w500/w1280 或本地 2000px+ 海报没必要全尺寸驻留。
enum ArtworkDecoder {
    private static let ioQueue = DispatchQueue(label: "lumen.artwork.io", qos: .utility,
                                               attributes: .concurrent)

    static func maxPixel(for variant: ArtworkVariant) -> Int {
        switch variant {
        case .poster:   return 900
        case .thumb:    return 900
        case .backdrop: return 1920
        }
    }

    static func cost(of image: PlatformImage) -> Int {
        #if os(macOS)
        if let rep = image.representations.first {
            return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
        }
        return max(1, Int(image.size.width * image.size.height * 4))
        #else
        if let cg = image.cgImage { return max(1, cg.bytesPerRow * cg.height) }
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        #endif
    }

    static func read(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: try? Data(contentsOf: url)) }
        }
    }

    static func write(_ data: Data, to url: URL) {
        ioQueue.async(flags: .barrier) { try? data.write(to: url, options: .atomic) }
    }

    static func decodeFile(_ url: URL, maxPixel: Int) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = downsample(source, maxPixel: maxPixel)
                if image == nil { try? FileManager.default.removeItem(at: url) }   // 坏缓存直接清掉
                continuation.resume(returning: image)
            }
        }
    }

    static func decode(_ data: Data, maxPixel: Int) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                guard data.count <= 32 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: downsample(source, maxPixel: maxPixel))
            }
        }
    }

    /// ImageIO 缩略图接口：直接按目标尺寸解码，并立即解码（ShouldCacheImmediately），
    /// 避免首次绘制时在主线程才做 JPEG 解码。
    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
