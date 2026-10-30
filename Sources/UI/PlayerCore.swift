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

    @Published private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying, backend == .mpv else { return }
            renderHost?.playbackStateChanged(isPlaying: isPlaying)
        }
    }
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
    /// 保持安全作用域/远程源在异步解封装期间存活；c3d6ab7 的 resourceLease。
    private var accessLease: (any MediaSource)?
    private var ticker: Timer?
    private var resumeSeek: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var avAudioGroup: AVMediaSelectionGroup?
    private var avSubtitleGroup: AVMediaSelectionGroup?
    /// 上一次读到的轨道数量，变了就重新拉一遍
    private var lastTrackCount = -1
    private var avLoadTask: Task<Void, Never>?
    /// AVPlayer 起播看门狗：遇到它处理不了的源会既不报错也不出画面，超时就换 mpv
    private var avWatchdog: Task<Void, Never>?
    private var colorModeChecked = false
    private var lastColorSignature: String?
    private var dolbyVisionApplied = false
    /// 是否已检查过「送往 GL 的像素格式」是否需要降到 8bit
    private var pixelFormatChecked = false
    /// ticker 计数：低频任务（轨道列表）不必每 0.25 秒做一次
    private var tickCount = 0
    private var desiredRate: Float = 1

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                guard self.backend == .av else { return }
                // @Published 每次赋值都会触发 objectWillChange，即便值没变；
                // 暂停时每 0.25 秒整页重绘播放器 UI，这里只在变化时才写。
                self.setIfChanged(\.currentTime, time.seconds)
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.setIfChanged(\.duration, d)
                }
                self.setIfChanged(\.isPlaying, self.player.rate > 0)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        ticker?.invalidate()
    }

    // MARK: 选后端

    static func needsMPV(_ target: PlaybackTarget) -> Bool {
        // AVFoundation 无法把 URLSession 的 Basic-auth challenge 代理给应用；
        // 受保护的远程文件由 mpv/FFmpeg 的 URL 认证路径处理。
        if target.credentials != nil { return true }
        let ext = target.url.pathExtension.lowercased()
        let native: Set<String> = ["mp4", "m4v", "mov", "qt"]
        if native.contains(ext) { return false }
        if target.url.absoluteString.contains(".m3u8") { return false }
        return MediaFileType.video.contains(ext)
    }

    var isMPVAvailable: Bool { true }

    // MARK: 载入

    func load(_ target: PlaybackTarget, startAt: Double) {
        stop()
        errorText = nil
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            errorText = "无法启用音频输出：\(error.localizedDescription)"
            return
        }
        #endif
        accessLease = target.accessLease
        resetTracks()
        let wantMPV = Self.needsMPV(target)
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
        AppLog.info("AV 播放：\(target.url.host ?? "本地文件") 扩展名=\(target.url.pathExtension) headers=\(target.headers.count)")
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

        // 看门狗：AVPlayer 对某些源会既不报错也不出画面（认证直链、部分封装），
        // 表现就是永久黑屏。12 秒还没起来就交给 mpv，别让用户干等。
        avWatchdog?.cancel()
        avWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.backend == .av, self.player.currentItem === item,
                      !self.isPlaying, self.currentTime < 0.1 else { return }
                self.fallbackToMPV(target, startAt: startAt, item: item,
                                   reason: "AV 12 秒未起播")
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }

        avLoadTask?.cancel()
        avLoadTask = Task {            do {
                // 容器可读、音轨可播不代表视频轨能由 AVPlayer 解码。
                // 部分 HEV1/HEVC MP4 会正常读取时长并推进播放时间，但始终没有画面；
                // 这是 c3d6ab7 中已验证过的检测与回退路径。
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard !Task.isCancelled, self.backend == .av,
                      self.player.currentItem === item else { return }
                guard !videoTracks.isEmpty else {
                    self.fallbackToMPV(target, startAt: startAt, item: item,
                                       reason: "AVPlayer 未发现视频轨")
                    return
                }
                for track in videoTracks {
                    let playable = try await track.load(.isPlayable)
                    guard !Task.isCancelled, self.backend == .av,
                          self.player.currentItem === item else { return }
                    if !playable {
                        self.fallbackToMPV(target, startAt: startAt, item: item,
                                           reason: "视频轨不兼容 AVPlayer")
                        return
                    }
                }
                let d = try await asset.load(.duration)
                guard !Task.isCancelled, self.backend == .av,
                      self.player.currentItem === item else { return }
                if d.seconds.isFinite { self.duration = d.seconds }
            } catch {
                guard !Task.isCancelled, self.backend == .av,
                      self.player.currentItem === item else { return }
                if (error as NSError).domain == NSURLErrorDomain,
                   [NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication].contains((error as NSError).code) {
                    self.errorText = "媒体源认证失败，请在文件源设置中重新保存账号密码并测试连接。"
                    self.isPlaying = false
                    return
                }
                self.fallbackToMPV(target, startAt: startAt, item: item,
                                   reason: error.localizedDescription)
                return
            }
            if startAt > 0 {
                await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.playImmediately(atRate: desiredRate)
            self.isPlaying = true
            self.avWatchdog?.cancel()
            self.avWatchdog = nil
        }
    }

    private func fallbackToMPV(_ target: PlaybackTarget, startAt: Double,
                               item: AVPlayerItem, reason: String) {
        guard backend == .av, player.currentItem === item else { return }
        AppLog.info("AV 回落 mpv：\(reason)")
        avWatchdog?.cancel()
        avWatchdog = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        resetTracks()
        backend = .mpv
        pendingTarget = target
        pendingStart = startAt
        if renderHost != nil { startMPVIfReady() }
    }

    // MARK: 控制

    func play() {
        switch backend {
        case .av:
            player.playImmediately(atRate: desiredRate); isPlaying = true
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
        avLoadTask?.cancel()
        avLoadTask = nil
        avWatchdog?.cancel()
        avWatchdog = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
                Self.destroyInBackground(ctx)
            }
        }
        pendingTarget = nil
        pendingStart = 0
        resumeSeek = 0
        accessLease = nil
        resetTracks()
        currentTime = 0
        duration = 0
        isPlaying = false
        #if os(iOS)
        // 关掉播放器就把音频会话交回去，否则别的 App 的音乐一直被压着
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        switch backend {
        case .av:
            if isPlaying { player.rate = rate }
        case .mpv:
            if mpvHandle != nil { mpvSet("speed", String(format: "%.2f", rate)) }
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
        colorModeChecked = false
        lastColorSignature = nil
        dolbyVisionApplied = false
        pixelFormatChecked = false
        tickCount = 0
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PlayerCore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// mpv_terminate_destroy 会等待解复用/解码/网络线程全部退出，网络源上常见几百毫秒甚至秒级，
    /// 以前在主线程同步调用，关闭播放器时 UI 卡住。mpv 句柄可跨线程销毁；调用前 render context
    /// 已在主线程释放、mpvHandle 已置空，不会再有人使用这个句柄。
    nonisolated private static func destroyInBackground(_ ctx: OpaquePointer) {
        let handle = MPVHandleBox(ctx)
        DispatchQueue.global(qos: .utility).async {
            mpv_terminate_destroy(handle.ctx)
        }
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
        if mpvHandle == nil { createMPV(target: target) }
        guard let ctx = mpvHandle else { return }
        if host.renderContextReady == false {
            guard host.createRenderContext(mpv: ctx) else {
                errorText = "mpv render context 创建失败"
                return
            }
        }

        let path = Self.mpvPath(for: target)
        AppLog.info("mpv loadfile 准备：\(target.url.lastPathComponent)")
        let lrc = mpvRun(ctx, "loadfile \"\(path)\"")
        AppLog.info("mpv loadfile rc=\(lrc)")
        // 注意：loadfile 之后立刻 seek 会被忽略（文件还没加载），
        // 改成记下目标位置，等 ticker 拿到 duration 后再 seek。
        resumeSeek = pendingStart
        mpvSet("speed", String(format: "%.2f", desiredRate))
        mpvSet("pause", "no")
        isPlaying = true
        pendingTarget = nil
        startTicker()
    }

    private func createMPV(target: PlaybackTarget) {
        guard let ctx = mpv_create() else {
            errorText = "无法创建 mpv 实例"
            return
        }
        mpvHandle = ctx
        if target.credentials == nil, !target.headers.isEmpty {
            let fields = target.headers.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,") }
                .joined(separator: ",")
            let rc = mpvSetOption(ctx, "http-header-fields", fields)
            guard rc >= 0 else {
                errorText = "无法配置媒体源认证（\(rc)）"
                mpv_terminate_destroy(ctx)
                mpvHandle = nil
                return
            }
        }
        mpvSetOption(ctx, "vo", "libmpv")          // 走 render API，不自建窗口
        mpvSetOption(ctx, "gpu-api", "opengl")
        // SwiftUI/GL 宿主是 SDR。显式转换 HDR10/HLG 的色域与传递函数。
        mpvSetOption(ctx, "target-prim", "bt.709")
        mpvSetOption(ctx, "target-trc", "srgb")
        #if os(iOS)
        // MPVKit iOS 构建里 videotoolbox-gl 是 disabled，直接 hwdec 会导致颜色错乱/蓝屏，
        // 用 -copy 让帧回到系统内存再由 GL 正常上传
        mpvSetOption(ctx, "hwdec", "videotoolbox-copy")
        // 10bit(p010) 走 GL 上传会偏绿。以前对所有视频都加 `vf=format=yuv420p`，
        // 让每一帧都在 CPU 上做一次 swscale（nv12 → yuv420p，4K 下单核满载、发热掉帧）。
        // 现在让 VideoToolbox 直接输出 8bit NV12：10bit 片源由硬件完成降位深，
        // 8bit 片源零额外开销；软解等仍输出 10bit 的情况由 ticker 里按需补 vf 兜底。
        mpvSetOption(ctx, "hwdec-image-format", "nv12")
        #else
        mpvSetOption(ctx, "hwdec", "videotoolbox")
        #endif
        mpvSetOption(ctx, "config", "no")
        mpvSetOption(ctx, "terminal", "no")
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
            mpv_terminate_destroy(ctx)
            mpvHandle = nil
            return
        }
        AppLog.info("mpv 初始化完成（render API 模式）")
    }

    /// MPVKit 当前的 iOS 构建没有 `http-user` / `http-password` 选项。
    /// FFmpeg 会可靠解析 URL userinfo 并发起 Basic 认证，因此仅在交给 MPV
    /// 的瞬时字符串上附加经过 URLComponents 编码的凭据；不写日志、不回传 UI。
    private static func mpvPath(for target: PlaybackTarget) -> String {
        guard !target.url.isFileURL,
              let credentials = target.credentials,
              var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false) else {
            return target.url.isFileURL ? target.url.path : target.url.absoluteString
        }
        components.user = credentials.username
        components.password = credentials.password
        return components.url?.absoluteString ?? target.url.absoluteString
    }



    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.backend == .mpv else { return }
                if let ctx = self.mpvHandle {
                    while let event = mpv_wait_event(ctx, 0)?.pointee, event.id != 0 {
                        if event.id == 7, let data = event.data { // MPV_EVENT_END_FILE
                            let end = data.load(as: MPVEndFileEvent.self)
                            if end.reason == 4 { // MPV_END_FILE_REASON_ERROR
                                self.errorText = end.error == -13
                                    ? "无法读取媒体文件，请检查网络连接，并在文件源设置中测试账号密码。"
                                    : "播放失败（\(end.error)），请检查文件或尝试其他视频。"
                                self.isPlaying = false
                                self.ticker?.invalidate()
                                AppLog.error("mpv 播放失败 code=\(end.error)")
                                return
                            }
                        }
                    }
                }
                self.tickCount &+= 1
                if let t = self.mpvDouble("time-pos") { self.setIfChanged(\.currentTime, t) }
                if let d = self.mpvDouble("duration"), d > 0 {
                    self.setIfChanged(\.duration, d)
                    if self.resumeSeek > 1 {
                        let target = min(self.resumeSeek, d - 3)
                        self.resumeSeek = 0
                        if target > 1 {
                            AppLog.info("续播：seek 到 \(Int(target))s / \(Int(d))s")
                            self.mpvCommand("seek \(target) absolute exact")
                        }
                    }
                }
                if let paused = self.mpvFlag("pause") { self.setIfChanged(\.isPlaying, !paused) }
                self.configureDolbyVisionIfNeeded()
                self.configurePixelFormatIfNeeded()
                // 轨道列表只在起播/切换时变化：起播前 2 秒逐 tick 检查，之后每 2 秒一次
                if self.tickCount <= 8 || self.tickCount % 8 == 0 {
                    self.refreshMPVTracksIfNeeded()
                }
            }
        }
    }

    private func configureDolbyVisionIfNeeded() {
        guard !colorModeChecked,
              let matrix = mpvString("video-params/colormatrix") else { return }
        let primaries = mpvString("video-params/primaries") ?? "-"
        let gamma = mpvString("video-params/gamma") ?? "-"
        let signature = "matrix=\(matrix) primaries=\(primaries) gamma=\(gamma)"
        if signature != lastColorSignature {
            AppLog.info("视频色彩：\(signature)")
            lastColorSignature = signature
        }
        // 拿到色彩参数后只判断一次，非杜比视界片源不再每 0.25 秒读 3 个字符串属性
        colorModeChecked = true
        guard matrix.lowercased().contains("dolbyvision") else { return }
        dolbyVisionApplied = true

        // libmpv render API 的旧 GPU 路径不处理 DoVi RPU。MPVKit 自带的 FFmpeg
        // libplacebo 滤镜先应用 RPU 并输出 BT.709 SDR，再由现有 GL 视图显示。
        let filter = "lavfi=[libplacebo=apply_dolbyvision=1:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p]"
        let hwRC = mpvSet("hwdec", "no")
        let filterRC = mpvSet("vf", filter)
        AppLog.info("Dolby Vision SDR 转换：hwdec rc=\(hwRC) filter rc=\(filterRC)")
        if filterRC < 0 {
            errorText = "该 Dolby Vision 视频无法启用色彩转换"
        }
    }

    /// 兜底：硬解失败回落软解、或 VideoToolbox 不接受 nv12 时，送往 GL 的仍可能是 10/12bit 格式，
    /// 只有这时才加 `vf=format=yuv420p`（iOS GL 上传高位深会偏绿）。
    private func configurePixelFormatIfNeeded() {
        #if os(iOS)
        guard !pixelFormatChecked, colorModeChecked,
              let format = mpvString("video-params/pixelformat") else { return }
        pixelFormatChecked = true
        guard !dolbyVisionApplied else { return }   // 杜比视界滤镜链已自带 format=yuv420p
        guard Self.isHighBitDepth(format) else { return }
        let rc = mpvSet("vf", "format=yuv420p")
        AppLog.info("高位深像素格式 \(format)，启用 8bit 转换 rc=\(rc)")
        #endif
    }

    nonisolated static func isHighBitDepth(_ format: String) -> Bool {
        format.lowercased().range(of: #"(p0(10|12|16)|p(9|10|12|14|16))"#,
                                  options: .regularExpression) != nil
    }
}

/// 把 mpv 句柄带到后台线程销毁用。mpv client API 本身线程安全。
private struct MPVHandleBox: @unchecked Sendable {
    let ctx: OpaquePointer
    init(_ ctx: OpaquePointer) { self.ctx = ctx }
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
