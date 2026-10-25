import SwiftUI
import AVFoundation

/// 一条音轨 / 字幕轨（内嵌或外挂）
struct MediaTrack: Identifiable, Hashable {
    let id: String          // "mpv:2" / "av:a0"
    let index: Int          // 后端用来切换的索引（mpv 的 track id / AV 的 option 序号）
    let title: String
    let detail: String?     // 语言 / 编码
    var isDefault = false
    var isSelected = false
}

/// 播放内核：按文件类型选后端。
/// - MP4 / MOV / M4V / HLS → AVPlayer（系统解码，省电、字幕/画中画生态好）
/// - MKV / AVI / RMVB / ISO / TS … → libmpv（VidHub 同款内核，格式全覆盖）
@MainActor
final class PlayerCore: ObservableObject {
    enum Backend { case av, mpv }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorText: String?
    @Published private(set) var backend: Backend = .av

    /// 内嵌音轨 / 字幕轨（容器里自带的，MKV 常见多语言多字幕）
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []

    /// AVPlayer 后端用（视图层要拿到它挂 AVPlayerLayer）
    let player = AVPlayer()

    /// mpv 句柄（MPVAPI.swift 里的封装要用）
    var mpvHandle: OpaquePointer?
    /// 画面宿主（macOS: NSOpenGLView，iOS: CAEAGLLayer）
    private weak var renderHost: (any MPVRenderHost)?
    private var pendingTarget: PlaybackTarget?
    private var pendingStart: Double = 0
    private var ticker: Timer?
    private var resumeSeek: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var avAudioGroup: AVMediaSelectionGroup?
    private var avSubtitleGroup: AVMediaSelectionGroup?
    /// 上一次读到的轨道数量，变了就重新拉一遍
    private var lastTrackCount = -1

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.backend == .av else { return }
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        ticker?.invalidate()
    }

    // MARK: 选后端

    static func needsMPV(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let native: Set<String> = ["mp4", "m4v", "mov", "qt"]
        if native.contains(ext) { return false }
        if url.absoluteString.contains(".m3u8") { return false }
        return MediaFileType.video.contains(ext)
    }

    var isMPVAvailable: Bool { true }

    // MARK: 载入

    func load(_ target: PlaybackTarget, startAt: Double) {
        resetTracks()
        #if os(iOS)
        // 杜比视界 / HDR 的 4K 片源交给 AVPlayer（系统原生支持 DV 与 HDR 映射），
        // mpv 0.37 的 render API 走的是 vo_gpu，不支持 DV，会整片偏绿。
        let name = target.url.lastPathComponent.lowercased()
        let isHDR = name.contains("2160p") || name.contains("4k")
            || name.contains("dolby") || name.contains("dv.") || name.contains(".dv")
            || name.contains("hdr")
        let wantMPV = !isHDR && Self.needsMPV(target.url)
        #else
        let wantMPV = Self.needsMPV(target.url)
        #endif
        if wantMPV {
            backend = .mpv
            pendingTarget = target
            pendingStart = startAt
            if renderHost != nil { startMPVIfReady() }
            return
        }

        backend = .av
        loadAV(target, startAt: startAt)
    }

    private func loadAV(_ target: PlaybackTarget, startAt: Double) {
        AppLog.info("AV 播放：\(target.url.absoluteString.prefix(70)) headers=\(target.headers.count)")
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if !target.headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = target.headers
        }
        let asset = AVURLAsset(url: target.url, options: options)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        // 音轨/字幕轨由界面手动选，别让系统按语言偏好自动挑
        player.appliesMediaSelectionCriteriaAutomatically = false
        Task { await loadAVTracks(item) }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }

        Task {
            do {
                let d = try await asset.load(.duration)
                if d.seconds.isFinite { self.duration = d.seconds }
            } catch {
                AppLog.error("AV 无法读取，回落 mpv：\(error.localizedDescription)")
                self.backend = .mpv
                self.pendingTarget = target
                self.pendingStart = startAt
                if self.renderHost != nil { self.startMPVIfReady() }
            }
            if startAt > 0 {
                await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            self.isPlaying = true
        }
    }

    // MARK: 控制

    func play() {
        switch backend {
        case .av:
            player.play(); isPlaying = true
        case .mpv:
            mpvSet("pause", "no"); isPlaying = true
        }
    }

    func pause() {
        switch backend {
        case .av:
            player.pause(); isPlaying = false
        case .mpv:
            mpvSet("pause", "yes"); isPlaying = false
        }
    }

    func seek(to seconds: Double) {
        let t = max(0, seconds)
        switch backend {
        case .av:
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        case .mpv:
            mpvCommand("seek \(t) absolute exact")
        }
    }

    /// 关闭播放器时调用：暂停、卸载、销毁 mpv 实例。
    /// 顺序很重要：先释放 render context，再 terminate mpv，否则会崩。
    func stop() {
        switch backend {
        case .av:
            player.pause()
            player.replaceCurrentItem(with: nil)
        case .mpv:
            ticker?.invalidate()
            ticker = nil
            mpvSet("pause", "yes")
            mpvCommand("stop")
            renderHost?.destroyRenderContext()
            if let ctx = mpvHandle {
                mpvHandle = nil
                mpv_terminate_destroy(ctx)
            }
        }
        isPlaying = false
    }

    func setRate(_ rate: Float) {
        switch backend {
        case .av:
            player.rate = rate
        case .mpv:
            mpvSet("speed", String(format: "%.2f", rate))
        }
    }

    // MARK: 音轨 / 字幕轨

    /// 切音轨（内嵌）
    func selectAudio(_ track: MediaTrack) {
        switch backend {
        case .mpv:
            mpvSet("aid", "\(track.index)")
        case .av:
            guard let group = avAudioGroup, group.options.indices.contains(track.index) else { return }
            player.currentItem?.select(group.options[track.index], in: group)
        }
        markSelected(track, in: &audioTracks)
    }

    /// 切内嵌字幕；nil = 关掉内嵌字幕
    func selectSubtitleTrack(_ track: MediaTrack?) {
        switch backend {
        case .mpv:
            mpvSet("sid", track.map { "\($0.index)" } ?? "no")
        case .av:
            guard let group = avSubtitleGroup else { return }
            if let track, group.options.indices.contains(track.index) {
                player.currentItem?.select(group.options[track.index], in: group)
            } else {
                player.currentItem?.select(nil, in: group)
            }
        }
        for i in subtitleTracks.indices {
            subtitleTracks[i].isSelected = (track != nil && subtitleTracks[i].id == track!.id)
        }
    }

    /// 外挂字幕接管时，把内嵌轨关掉，避免两套字幕叠在一起
    func disableEmbeddedSubtitles() {
        selectSubtitleTrack(nil)
    }

    private func markSelected(_ track: MediaTrack, in list: inout [MediaTrack]) {
        for i in list.indices { list[i].isSelected = (list[i].id == track.id) }
    }

    private func resetTracks() {
        audioTracks = []
        subtitleTracks = []
        avAudioGroup = nil
        avSubtitleGroup = nil
        lastTrackCount = -1
    }

    /// AVPlayer：从 asset 里读可选音轨 / 字幕组
    private func loadAVTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            avAudioGroup = group
            audioTracks = group.options.enumerated().map { i, option in
                MediaTrack(id: "av:a\(i)", index: i,
                           title: Self.avName(option, fallback: "音轨 \(i + 1)"),
                           detail: option.extendedLanguageTag ?? option.locale?.identifier)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            avSubtitleGroup = group
            subtitleTracks = group.options.enumerated().map { i, option in
                MediaTrack(id: "av:s\(i)", index: i,
                           title: Self.avName(option, fallback: "字幕 \(i + 1)"),
                           detail: option.extendedLanguageTag ?? option.locale?.identifier)
            }
        }
    }

    private static func avName(_ option: AVMediaSelectionOption, fallback: String) -> String {
        let name = option.displayName
        return name.isEmpty ? fallback : name
    }

    /// 轨道里的语言代码翻成中文，菜单里别直接甩 jpn / chi
    static func langName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let map: [String: String] = [
            "jpn": "日语", "ja": "日语",
            "chi": "中文", "zho": "中文", "zh": "中文", "chs": "简体中文", "cht": "繁体中文",
            "yue": "粤语",
            "eng": "英语", "en": "英语",
            "kor": "韩语", "ko": "韩语",
            "fra": "法语", "fre": "法语", "fr": "法语",
            "deu": "德语", "ger": "德语", "de": "德语",
            "spa": "西班牙语", "es": "西班牙语",
            "ita": "意大利语", "it": "意大利语",
            "rus": "俄语", "ru": "俄语",
            "tha": "泰语", "th": "泰语"
        ]
        return map[code.lowercased()]
    }

    /// mpv 的 codec 名（hdmv_pgs_subtitle / subrip …）换成好读的短标签
    static func codecName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw.lowercased()
        if key.contains("pgs") { return "PGS" }
        if key.contains("subrip") || key == "srt" { return "SRT" }
        if key.contains("ass") || key.contains("ssa") { return "ASS" }
        if key.contains("mov_text") || key.contains("tx3g") { return "MP4 文本" }
        if key.contains("dvd_subtitle") || key.contains("vobsub") { return "VobSub" }
        if key.contains("truehd") { return "TrueHD" }
        if key.contains("dts") { return "DTS" }
        if key.contains("eac3") { return "EAC3" }
        if key.contains("ac3") { return "AC3" }
        if key.contains("aac") { return "AAC" }
        if key.contains("flac") { return "FLAC" }
        if key.contains("opus") { return "Opus" }
        return raw.uppercased()
    }

    /// mpv：容器里的 track-list 变了就重新拉一遍（换文件、加字幕都会变）
    private func refreshMPVTracksIfNeeded() {
        guard backend == .mpv, mpvHandle != nil else { return }
        let count = Int(mpvInt("track-list/count") ?? 0)
        guard count != lastTrackCount else { return }
        lastTrackCount = count

        var audio: [MediaTrack] = []
        var subs: [MediaTrack] = []
        for i in 0..<count {
            guard let type = mpvString("track-list/\(i)/type") else { continue }
            let id = Int(mpvInt("track-list/\(i)/id") ?? 0)
            let lang = mpvString("track-list/\(i)/lang")
            let title = mpvString("track-list/\(i)/title")
            let codecRaw = mpvString("track-list/\(i)/codec")
            let selected = mpvFlag("track-list/\(i)/selected") ?? false
            let isDefault = mpvFlag("track-list/\(i)/default") ?? false
            let codec = Self.codecName(codecRaw)
            let detail = codec
            let name = (title?.isEmpty == false ? title : nil)
                ?? Self.langName(lang)
                ?? (type == "audio" ? "音轨 \(audio.count + 1)" : "字幕 \(subs.count + 1)")

            switch type {
            case "audio":
                audio.append(MediaTrack(id: "mpv:\(id)", index: id, title: name,
                                        detail: detail,
                                        isDefault: isDefault, isSelected: selected))
            case "sub":
                subs.append(MediaTrack(id: "mpv:\(id)", index: id, title: name,
                                       detail: detail,
                                       isDefault: isDefault, isSelected: selected))
            default:
                break
            }
        }
        audioTracks = audio
        subtitleTracks = subs
        #if DEBUG
        AppLog.info("TRACKS 音轨 \(audio.count) 条：\(audio.map { "\($0.title)/\($0.detail ?? "-")\($0.isSelected ? "*" : "")" })")
        AppLog.info("TRACKS 字幕 \(subs.count) 条：\(subs.map { "\($0.title)/\($0.detail ?? "-")\($0.isSelected ? "*" : "")" })")
        #endif
    }

    // MARK: 视图挂载（mpv 用 wid 嵌进 NSView）

    func attachRenderHost(_ host: any MPVRenderHost) {
        renderHost = host
        startMPVIfReady()
    }

    private func startMPVIfReady() {
        guard let target = pendingTarget, let host = renderHost else { return }
        if mpvHandle == nil { createMPV() }
        guard let ctx = mpvHandle else { return }
        if host.renderContextReady == false {
            guard host.createRenderContext(mpv: ctx) else {
                errorText = "mpv render context 创建失败"
                return
            }
        }

        // 请求头（WebDAV 的 Basic 认证等）
        if !target.headers.isEmpty {
            let fields = target.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
            mpvSetOption(ctx, "http-header-fields", fields)
        }

        let path = target.url.isFileURL ? target.url.path : target.url.absoluteString
        AppLog.info("mpv loadfile 准备：\(path.prefix(80))")
        let lrc = mpvRun(ctx, "loadfile \"\(path)\"")
        AppLog.info("mpv loadfile rc=\(lrc)")
        // 注意：loadfile 之后立刻 seek 会被忽略（文件还没加载），
        // 改成记下目标位置，等 ticker 拿到 duration 后再 seek。
        resumeSeek = pendingStart
        mpvSet("pause", "no")
        isPlaying = true
        pendingTarget = nil
        startTicker()
    }

    private func createMPV() {
        guard let ctx = mpv_create() else {
            errorText = "无法创建 mpv 实例"
            return
        }
        mpvHandle = ctx
        mpvSetOption(ctx, "vo", "libmpv")          // 走 render API，不自建窗口
        mpvSetOption(ctx, "gpu-api", "opengl")
        #if os(iOS)
        // MPVKit iOS 构建里 videotoolbox-gl 是 disabled，直接 hwdec 会导致颜色错乱/蓝屏，
        // 用 -copy 让帧回到系统内存再由 GL 正常上传
        mpvSetOption(ctx, "hwdec", "videotoolbox-copy")
        // 10bit(p010) 走 GL 上传会偏绿，先转成 8bit yuv420p
        mpvSetOption(ctx, "vf", "format=yuv420p")
        #else
        mpvSetOption(ctx, "hwdec", "videotoolbox")
        #endif
        mpvSetOption(ctx, "config", "no")
        mpvSetOption(ctx, "terminal", "no")
        #if DEBUG
        mpvSetOption(ctx, "log-file", StorePaths.root.appendingPathComponent("mpv.log").path)
        mpvSetOption(ctx, "msg-level", "all=v")
        #endif
        mpvSetOption(ctx, "keep-open", "no")
        mpvSetOption(ctx, "input-media-keys", "no")
        mpvSetOption(ctx, "input-default-bindings", "no")
        mpvSetOption(ctx, "osc", "no")
        mpvSetOption(ctx, "osd-level", "0")
        // 只关掉「自动加载同名字幕文件」——内嵌字幕轨还要能手动选。
        // 外挂字幕由 SwiftUI 自己画（中文字体、字号、描边都可控），
        // 交给 mpv 渲染时没有 fontconfig 中文会变豆腐块，所以指定系统字体兜底。
        mpvSetOption(ctx, "sub-auto", "no")
        #if os(macOS)
        // 沙盒里读不到 PingFang 的私有路径（FontServices.framework），会全是方框。
        // 换用 /System/Library/Fonts 下沙盒可读的中文字体，并强制覆盖内嵌样式里的字体名。
        mpvSetOption(ctx, "sub-font", "Hiragino Sans GB")
        mpvSetOption(ctx, "sub-fonts-dir", "/System/Library/Fonts:/System/Library/Fonts/Supplemental")
        mpvSetOption(ctx, "sub-ass-override", "force")
        #else
        mpvSetOption(ctx, "sub-font", "PingFang SC")
        #endif
        mpvSetOption(ctx, "sub-codepage", "auto")
        mpvSetOption(ctx, "cache", "yes")
        mpvSetOption(ctx, "demuxer-max-bytes", "256MiB")
        // VidHub（MediaCenter）在沙盒里用的是 ao=avfoundation（走 AVAudioEngine），
        // 不是 coreaudio —— coreaudio 在沙盒下会让进程直接退出。
        #if os(iOS)
        // MPVKit 的 iOS 构建：-Dcoreaudio=disabled，只编了 audiounit / avfoundation
        mpvSetOption(ctx, "ao", "audiounit")
        #else
        mpvSetOption(ctx, "ao", "coreaudio")
        #endif
        mpvSetOption(ctx, "audio-device", "auto")

        mpvSetOption(ctx, "volume-max", "100")

        let rc = mpv_initialize(ctx)
        AppLog.info("mpv 初始化 rc=\(rc)（render API 模式）")
        guard rc >= 0 else {
            errorText = "mpv 初始化失败（rc=\(rc)）"
            return
        }
        AppLog.info("mpv 初始化完成（render API 模式）")
    }



    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.backend == .mpv else { return }
                if let t = self.mpvDouble("time-pos") { self.currentTime = t }
                if let d = self.mpvDouble("duration"), d > 0 {
                    self.duration = d
                    if self.resumeSeek > 1 {
                        let target = min(self.resumeSeek, d - 3)
                        self.resumeSeek = 0
                        if target > 1 {
                            AppLog.info("续播：seek 到 \(Int(target))s / \(Int(d))s")
                            self.mpvCommand("seek \(target) absolute exact")
                        }
                    }
                }
                if let paused = self.mpvFlag("pause") { self.isPlaying = !paused }
                self.refreshMPVTracksIfNeeded()
            }
        }
    }
}

// MARK: - mpv 画面（wid 嵌入）

#if os(macOS)
struct MPVSurface: NSViewRepresentable {
    let core: PlayerCore

    func makeNSView(context: Context) -> MPVGLView {
        MPVGLView(core: core)
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {
        nsView.core = core
    }
}
#endif
