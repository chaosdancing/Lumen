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
    private var failed: Set<String> = []

    private var cacheDir: URL {
        let dir = StorePaths.root.appendingPathComponent("Caches/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cached(_ itemID: String, variant: ArtworkVariant = .poster) -> PlatformImage? {
        memory["\(Self.cacheVersion)#\(itemID)#\(variantKey(variant))"]
    }

    func image(for item: MediaItem, variant: ArtworkVariant = .poster,
               in store: AppStore) async -> PlatformImage? {
        let key = "\(Self.cacheVersion)#\(item.id)#\(variantKey(variant))"
        if let hit = memory[key] { return hit }
        if failed.contains(key) { return nil }

        let file = cacheDir.appendingPathComponent(Self.hash(key) + ".img")
        let useDiskCache = (variant != .thumb)   // 缩略图不落盘，避免旧规则缓存一直生效
        if useDiskCache, let data = try? Data(contentsOf: file), let img = PlatformImage(data: data) {
            memory[key] = img
            return img
        }

        var data: Data?
        let preferLocal = Preferences.shared.preferLocalPoster || variant != .poster

        // 横版头图优先用匹配过片名的 TMDB 剧照。目录里的通用 fanart.jpg
        // 可能属于另一部片，放在网络匹配失败后再回退。
        if variant == .backdrop,
           let url = await MetadataStore.shared.bestBackdropURL(for: item) {
            data = try? await Self.fetch(url)
        }
        // 1. 片源目录里已有的图片（-poster / -fanart / -landscape / -thumb / poster.jpg …）
        if data == nil, preferLocal,
           let path = await LocalArtworkResolver.shared.path(for: item, variant: variant, in: store),
           let raw = try? await store.data(for: item, path: path) {
            data = raw
        }
        // 2. 媒体服务器官方海报（只对 poster 有意义）
        if data == nil, variant == .poster, let url = store.posterURL(for: item) {
            data = try? await Self.fetch(url)
        }
        // 3. TMDB 刮削图
        if data == nil, variant == .poster,
           let url = MetadataStore.shared.cachedPosterURL(for: item.id) {
            data = try? await Self.fetch(url)
        }
        // 3.5 缩略图本地没有 → 用刮削到的海报兜底
        if data == nil, variant == .thumb,
           let url = MetadataStore.shared.cachedPosterURL(for: item.id) {
            data = try? await Self.fetch(url)
        }
        // 4. 横版图缺失时退回竖版海报
        if data == nil, variant == .backdrop {
            return await image(for: item, variant: .poster, in: store)
        }
        // 5. 本地视频抽帧
        if data == nil, variant != .backdrop, store.source(for: item.sourceID)?.kind == .local {
            data = await frameThumbnail(for: item, in: store)
        }

        guard let data, let img = PlatformImage(data: data) else {
            failed.insert(key)
            return nil
        }
        memory[key] = img
        if useDiskCache { try? data.write(to: file, options: .atomic) }
        return img
    }

    private func variantKey(_ v: ArtworkVariant) -> String {
        switch v {
        case .poster:   return "p"
        case .backdrop: return "b"
        case .thumb:    return "t"
        }
    }

    /// 列表刷新（重新扫描）后清掉失败记录，允许重试
    func resetFailures() { failed.removeAll() }

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
