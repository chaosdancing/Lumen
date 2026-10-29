import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#endif

/// 只在容器里放了对应 flag 文件时才跑，用于无界面验证内核能力
enum DebugProbes {
    @MainActor
    static func run(store: AppStore) async {
        await webDAVProbe(store: store)
        await mpvProbe(store: store)
        await metaIsolationProbe(store: store)
        await mpvWindowProbe(store: store)
        await thumbProbe(store: store)
    }

    /// 仅供真机排障：结果落入独立文件，不包含用户名、密码或完整 URL。
    @MainActor
    private static func webDAVProbe(store: AppStore) async {
        #if DEBUG
        let flag = StorePaths.root.appendingPathComponent("webdav-probe.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let resultURL = StorePaths.root.appendingPathComponent("webdav-probe-result.txt")
        let probeLines = raw.split(whereSeparator: \.isNewline).map(String.init)
        let id = probeLines.first ?? ""
        guard let config = store.sources.first(where: { $0.id.uuidString == id }) else {
            try? "source-not-found".write(to: resultURL, atomically: true, encoding: .utf8)
            return
        }
        let normalized = config.normalized()
        if probeLines.count == 2 {
            let actual = SHA256.hash(data: Data("\(normalized.username):\(normalized.password)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            AppLog.info("DAV credential matchesCurl=\(actual == probeLines[1])")
        }
        // 对照旧版请求与 curl 的最小 PROPFIND，凭据只取设备内存。
        for isolated in [false, true] {
            let settings = isolated ? URLSessionConfiguration.ephemeral : .default
            if isolated { settings.urlCredentialStorage = nil }
            let session = URLSession(configuration: settings,
                                     delegate: LocalNetworkTrustDelegate.shared, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            do {
                let source = try MediaSourceFactory.make(normalized)
                var request = URLRequest(url: try await source.playURL(for: ""))
                request.timeoutInterval = 10
                request.httpMethod = "PROPFIND"
                request.setValue("1", forHTTPHeaderField: "Depth")
                request.setValue("Basic " + Data("\(normalized.username):\(normalized.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                let (_, response) = try await session.data(for: request)
                AppLog.info("DAV comparison isolated=\(isolated) status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
            } catch {
                AppLog.info("DAV comparison isolated=\(isolated) error=\((error as NSError).code)")
            }
        }
        do {
            let source = try WebDAVMediaSource(config: normalized)
            let entries = try await source.list(path: "")
            try? "success host=\(normalized.host) port=\(normalized.port) entries=\(entries.count)"
                .write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            try? "failure host=\(normalized.host) port=\(normalized.port) code=\((error as NSError).code)"
                .write(to: resultURL, atomically: true, encoding: .utf8)
        }
        #endif
    }

    /// 诊断：容器里放 `shot.flag`（内容可写 `宽x高`）→ 把主窗口内容截成 shot.png。
    /// 不依赖系统的屏幕录制权限，用于核对界面版式。
    @MainActor
    static func captureWindowIfRequested() async {
        #if os(macOS)
        let flag = StorePaths.root.appendingPathComponent("shot.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)

        let spec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quick = spec.contains("quick")
        // 等界面把图片、元数据都加载完（播放器控制条 3.5s 后自动隐藏，抓播放器时用 quick）
        if !quick { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        else { try? await Task.sleep(nanoseconds: 1_000_000_000) }

        // 抓播放器时按 identifier 找，别抓到主窗口
        let wantsPlayer = spec.contains("player")
        guard let window = (wantsPlayer
                            ? NSApp.windows.first { $0.identifier?.rawValue == "player" && $0.isVisible }
                            : nil)
                ?? NSApp.windows.first(where: { $0.isKeyWindow && $0.contentView != nil })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        else {
            AppLog.error("SHOT 找不到可见窗口")
            return
        }

        // 走和「设置 → 外观」完全一样的链路，验证切换是否即时生效
        if spec.contains("dark") {
            Preferences.shared.appearance = "dark"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        } else if spec.contains("light") {
            Preferences.shared.appearance = "light"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        if let size = parseSize(spec), size.width > 400, size.height > 300 {
            window.setContentSize(size)
            window.center()
            try? await Task.sleep(nanoseconds: quick ? 500_000_000 : 1_500_000_000)
        }

        // 窗口被别的窗口挡住时，抓到的可能是旧画面：先激活并提到最前
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 900_000_000)

        guard let view = window.contentView else {
            AppLog.error("SHOT 没有 contentView")
            return
        }

        // 抓自己的窗口不需要屏幕录制权限
        var cgImage: CGImage?
        if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                              CGWindowID(window.windowNumber),
                                              [.boundsIgnoreFraming, .bestResolution]) {
            cgImage = shot
        }

        if cgImage == nil {
            let scale = window.backingScaleFactor
            let width = Int(view.bounds.width * scale)
            let height = Int(view.bounds.height * scale)
            guard width > 0, height > 0,
                  let ctx = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                AppLog.error("SHOT 无法创建位图上下文")
                return
            }
            ctx.scaleBy(x: scale, y: scale)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            if let layer = view.layer {
                layer.render(in: ctx)
            } else {
                view.draw(view.bounds)
            }
            cgImage = ctx.makeImage()
        }

        guard let cgImage else {
            AppLog.error("SHOT 生成 CGImage 失败")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            AppLog.error("SHOT PNG 编码失败")
            return
        }
        let out = StorePaths.root.appendingPathComponent("shot.png")
        try? data.write(to: out, options: .atomic)
        AppLog.info("SHOT 已保存 \(out.path) \(cgImage.width)x\(cgImage.height)")
        #endif
    }

    private static func parseSize(_ spec: String) -> CGSize? {
        let parts = spec.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 诊断：容器里放 `meta-test.flag`，把 MetadataStore 的初始化和 load 拆开定位
    @MainActor
    private static func metaIsolationProbe(store: AppStore) async {
        let flag = StorePaths.root.appendingPathComponent("meta-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let item = store.library.first(where: { $0.path == target }) else {
            AppLog.error("META PROBE 找不到条目")
            return
        }
        AppLog.info("META PROBE 1 触碰单例前")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let count = MetadataStore.shared.items.count
        AppLog.info("META PROBE 2 单例就绪 items=\(count)")
        try? await Task.sleep(nanoseconds: 400_000_000)

        AppLog.info("META PROBE 3 读 Preferences / apiKey")
        let preferNFO = Preferences.shared.preferNFO
        let hasKey = TMDBClient.apiKey != nil
        AppLog.info("META PROBE 4 preferNFO=\(preferNFO) hasKey=\(hasKey)")
        try? await Task.sleep(nanoseconds: 400_000_000)

        AppLog.info("META PROBE 5a 调 NFOParser")
        let nfo = await NFOParser.metadata(for: item, in: store)
        AppLog.info("META PROBE 5b NFO → \(nfo?.title ?? "nil")")
        try? await Task.sleep(nanoseconds: 300_000_000)

        AppLog.info("META PROBE 5c 调 scrape")
        let scraped = try? await TMDBClient.shared.scrape(itemID: item.id,
                                                          query: item.title,
                                                          year: item.year,
                                                          isSeries: false)
        AppLog.info("META PROBE 5d scrape → \(scraped?.title ?? "nil")")
    }

    /// 诊断：容器里放 `mpv-wid-test.flag`，用真实 NSWindow 走一遍 wid 嵌入路径
    @MainActor
    private static func mpvWindowProbe(store: AppStore) async {
        #if os(macOS)
        let flag = StorePaths.root.appendingPathComponent("mpv-wid-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let item = store.library.first(where: { $0.path == target }) else {
            AppLog.error("WID PROBE 找不到条目")
            return
        }
        do {
            let pb = try await store.playbackTarget(for: item)
            // 用屏幕内、可见的窗口测（离屏窗口的 Metal drawable 可能为空）
            let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 640, height: 360),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let core = PlayerCore()
            let glView = MPVGLView(core: core)
            glView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            window.contentView = glView
            window.orderFrontRegardless()
            let resume = store.record(for: item.id)?.position ?? 0
            AppLog.info("GL PROBE 续播起点=\(Int(resume))s")
            core.load(pb, startAt: resume)
            for i in 0..<24 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if core.duration > 0, core.currentTime > 0 || i > 6 {
                    AppLog.info("GL PROBE 成功 duration=\(String(format: "%.1f", core.duration))s t=\(String(format: "%.1f", core.currentTime)) 播放中=\(core.isPlaying) 耗时\((i + 1) * 500)ms")
                    window.orderOut(nil)
                    return
                }
            }
            AppLog.error("GL PROBE 超时：12 秒没拿到时长，error=\(core.errorText ?? "无")")
            window.orderOut(nil)
        } catch {
            AppLog.error("WID PROBE 失败：\(error.logDescription)")
        }
        #endif
    }

    /// 诊断：容器里放 `thumb-test.flag`（内容为库内相对路径），检查封面解析链路
    @MainActor
    private static func thumbProbe(store: AppStore) async {
        let flag = StorePaths.root.appendingPathComponent("thumb-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let targets = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for target in targets.prefix(4) {
            await inspect(path: target, store: store)
        }
    }

    @MainActor
    private static func inspect(path target: String, store: AppStore) async {
        guard let item = store.library.first(where: { $0.path == target }) else {
            AppLog.error("THUMB PROBE 找不到条目：\(target)")
            return
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        AppLog.info("THUMB PROBE dir=\(dir)")
        if let src = try? MediaSourceFactory.make(store.source(for: item.sourceID)!) {
            if let list = try? await src.list(path: dir) {
                let images = list.filter { !$0.isDirectory && MediaFileType.isImage($0.name) }
                AppLog.info("THUMB PROBE 目录内图片 \(images.count) 个：\(images.prefix(3).map(\.name))")
            } else {
                AppLog.error("THUMB PROBE 列目录失败")
            }
        }
        let subs = await store.subtitleCandidates(for: item)
        AppLog.info("THUMB PROBE 字幕候选 \(subs.count) 个：\(subs.map { ($0 as NSString).lastPathComponent })")
        let cues = subs.isEmpty ? [] : await store.subtitleCues(for: item, path: subs[0])
        AppLog.info("THUMB PROBE 首条字幕解析出 \(cues.count) 条")

        // 对比：剧集根目录的 thumb.png 与每集 -thumb.jpg 是否是同一张图
        if let src = try? MediaSourceFactory.make(store.source(for: item.sourceID)!) {
            let showRoot = ((item.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            if let list = try? await src.list(path: showRoot) {
                for name in list.filter({ !$0.isDirectory && MediaFileType.isImage($0.name) }).map(\.name) {
                    let p = "\(showRoot)/\(name)"
                    if let d = try? await src.data(for: p) {
                        let h = d.withUnsafeBytes { buf -> String in
                            var hash: UInt64 = 0xcbf29ce484222325
                            for b in buf { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
                            return String(format: "%016llx", hash)
                        }
                        AppLog.info("THUMB PROBE 根图 \(name) \(d.count)B \(h)")
                    }
                }
            }
        }

        // 把本地缩略图落盘，便于人工核对是不是同一张
        if let p = await LocalArtworkResolver.shared.path(for: item, variant: .thumb, in: store),
           let d = try? await store.data(for: item, path: p) {
            let ep = item.episode ?? 0
            let out = StorePaths.root.appendingPathComponent("thumb-\(ep).jpg")
            try? d.write(to: out)
            AppLog.info("THUMB PROBE 已存 \(out.path)")
        }

        let storeArtwork = ArtworkStore()
        AppLog.info("THUMB PROBE 即将调用 MetadataStore.load")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MetadataStore.shared.load(for: item, in: store)
        try? await Task.sleep(nanoseconds: 300_000_000)
        AppLog.info("THUMB PROBE metadata → \(MetadataStore.shared.metadata(for: item.id)?.title ?? "nil") cast=\(MetadataStore.shared.metadata(for: item.id)?.cast.count ?? -1)")
        for variant in [ArtworkVariant.poster, .backdrop, .thumb] {
            let img = await storeArtwork.image(for: item, variant: variant, in: store)
            AppLog.info("THUMB PROBE ArtworkStore \(variant) → \(img == nil ? "nil" : "有图 \(Int(img!.size.width))x\(Int(img!.size.height))")")
            if let path = await LocalArtworkResolver.shared.path(for: item, variant: variant, in: store) {
                let size = (try? await store.data(for: item, path: path))?.count ?? -1
                AppLog.info("THUMB PROBE \(variant) → \(path) (\(size) bytes)")
            } else {
                AppLog.error("THUMB PROBE \(variant) → 未找到")
            }
        }
    }

    @MainActor
    private static func mpvProbe(store: AppStore) async {
        #if os(macOS)
        let flag = StorePaths.root.appendingPathComponent("mpv-test.flag")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: flag)
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let item = store.library.first(where: { $0.path == target }) else {
            AppLog.error("MPV PROBE 找不到条目：\(target)")
            return
        }
        do {
            let pb = try await store.playbackTarget(for: item)
            AppLog.info("MPV PROBE 开始 \(pb.url.lastPathComponent)")

            guard let ctx = mpv_create() else { AppLog.error("MPV PROBE create 失败"); return }
            AppLog.info("MPV PROBE create ok")

            AppLog.info("MPV PROBE vo=null rc=\(mpvSetOption(ctx, "vo", "null"))")
            AppLog.info("MPV PROBE ao=null rc=\(mpvSetOption(ctx, "ao", "null"))")
            AppLog.info("MPV PROBE hwdec=no rc=\(mpvSetOption(ctx, "hwdec", "no"))")
            if !pb.headers.isEmpty {
                let fields = pb.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
                AppLog.info("MPV PROBE headers rc=\(mpvSetOption(ctx, "http-header-fields", fields))")
            }

            AppLog.info("MPV PROBE initialize…")
            let rc = mpv_initialize(ctx)
            AppLog.info("MPV PROBE init rc=\(rc)")
            guard rc >= 0 else { return }

            mpvRun(ctx, "loadfile \"\(pb.url.absoluteString)\"")
            for i in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let d = mpvGetDouble(ctx, "duration"), d > 0 {
                    let w = mpvGetInt(ctx, "width") ?? -1
                    let h = mpvGetInt(ctx, "height") ?? -1
                    AppLog.info("MPV PROBE 成功 duration=\(String(format: "%.1f", d))s \(w)x\(h) 耗时\((i + 1) * 500)ms")
                    mpv_terminate_destroy(ctx)
                    return
                }
            }
            AppLog.error("MPV PROBE 超时：10 秒没拿到 duration")
            mpv_terminate_destroy(ctx)
        } catch {
            AppLog.error("MPV PROBE 失败：\(error.logDescription)")
        }
        #endif
    }
}
