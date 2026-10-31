import SwiftUI
import AVFoundation
import AVKit

// MARK: - 画面挂载

#if os(macOS)
struct MacPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(player: player) }
    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        /// 不拦截鼠标：否则 SwiftUI 的单击/双击手势收不到事件
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        init(player: AVPlayer) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
struct IOSPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView { PlayerUIView(player: player) }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        init(player: AVPlayer) {
            super.init(frame: .zero)
            backgroundColor = .black
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

// MARK: - 播放页

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var presenter: PlayerPresenter

    let item: MediaItem

    @StateObject private var engine = PlayerCore()
    @State private var loadError: String?
    @State private var controlsVisible = true
    @State private var lastTapTime = Date.distantPast
    @State private var hideTask: Task<Void, Never>?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var rate: Float = 1.0
    @State private var subtitleCandidates: [String] = []
    @State private var selectedSubtitle: String?
    @State private var cues: [SubtitleCue] = []
    @ObservedObject private var prefs = Preferences.shared
    @State private var target: PlaybackTarget?
    @State private var shotMessage: String?
    @State private var subtitleError: String?
    @State private var seekHint: String?
    @State private var seekHintTask: Task<Void, Never>?

    private var title: String { item.seriesTitle ?? item.title }
    private var subtitleLine: String? {
        guard item.seriesTitle != nil else { return item.year.map(String.init) }
        return item.title
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surfaceView.ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // 单击只唤出控制层；双击由 PlayerWindowController 的本地监听处理（全屏）
                    revealControls()
                }
                .onContinuousHover { phase in
                    if case .active = phase { revealControls() }
                }

            subtitleOverlay

            if let seekHint {
                Text(seekHint)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    .transition(.opacity)
            }

            if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(loadError).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("关闭") { closePlayer() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            }

            if engine.errorText != nil {
                VStack(spacing: 8) {
                    Image(systemName: "play.slash").font(.largeTitle)
                    Text(engine.errorText!).multilineTextAlignment(.center).frame(maxWidth: 460)
                    Button("关闭") { closePlayer() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(24)
            }

            if controlsVisible {
                controls.transition(.opacity)
            }
        }
        #if os(macOS)
        .onExitCommand { closePlayer() }
        #endif
        .background(Color.black)
        // 播放器是纯深色界面，固定深色外观：浅色模式下系统控件（Menu 标签、菜单弹层）才是白字
        .preferredColorScheme(.dark)
        .focusable()
        .onKeyPress(.space) { engine.isPlaying ? engine.pause() : engine.play(); return .handled }
        .onKeyPress(.leftArrow) { skip(-prefs.rewindInterval); return .handled }
        .onKeyPress(.rightArrow) { skip(prefs.forwardInterval); return .handled }
        .onAppear {
            #if os(macOS)
            PlayerWindowController.shared.onSingleClick = {
                revealControls()
            }
            PlayerWindowController.shared.onDoubleClick = {
                if prefs.doubleClickPause {
                    engine.isPlaying ? engine.pause() : engine.play()
                } else {
                    PlayerWindowController.shared.toggleFullScreen()
                }
            }
            PlayerWindowController.shared.onMiniaturize = {
                if prefs.pauseOnMinimize { engine.pause() }
            }
            #endif
        }
        .task {
            await load()
            // 播放中每 5 秒落一次进度，异常退出也不丢
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                if engine.isPlaying { saveProgress() }
            }
        }
        .onDisappear {
            saveProgress()
            store.flushProgressSync()
            if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
            playbackEndObserver = nil
            #if os(macOS)
            PlayerWindowController.shared.onMiniaturize = nil
            #endif
            engine.stop()
            hideTask?.cancel()
        }
    }

    @ViewBuilder private var surfaceView: some View {
        #if os(macOS)
        if engine.backend == .mpv {
            MPVSurface(core: engine)
        } else {
            MacPlayerLayerView(player: engine.player)
        }
        #else
        if engine.backend == .mpv {
            MPVSurfaceiOS(core: engine)
        } else {
            IOSPlayerLayerView(player: engine.player)
        }
        #endif
    }

    // MARK: 控制层

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitleLine {
                    Text(subtitleLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer()
            Button {
                #if os(macOS)
                PlayerWindowController.shared.toggleFullScreen()
                #endif
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PlayerGlassButton())
            .help("全屏")

            Button { closePlayer() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PlayerGlassButton())
            .keyboardShortcut(.escape, modifiers: [])
            .help("关闭")
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    private var centerControls: some View {
        HStack(spacing: 44) {
            Button { skip(-prefs.rewindInterval) } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 25))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { engine.isPlaying ? engine.pause() : engine.play() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .medium))
                    .frame(width: 72, height: 72)
                    .background(.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button { skip(prefs.forwardInterval) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 25))
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Text(timeText(isScrubbing ? scrubValue : engine.currentTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 58, alignment: .trailing)

                ScrubBar(value: isScrubbing ? scrubValue : engine.currentTime,
                         duration: engine.duration,
                         onScrub: { v in
                             if !isScrubbing { isScrubbing = true }
                             scrubValue = v
                         },
                         onCommit: { v in
                             engine.seek(to: v)
                             isScrubbing = false
                         })

                Text(timeText(engine.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 58, alignment: .leading)
            }
            .padding(.horizontal, 22)

            HStack(spacing: 18) {
                if engine.audioTracks.count > 1 { audioMenu }
                subtitleMenu
                rateMenu
                Button { captureScreenshot() } label: {
                    Label("截图", systemImage: "camera")
                        .font(.caption)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                if let shotMessage {
                    Text(shotMessage).font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(engine.audioTracks) { track in
                Button {
                    engine.selectAudio(track)
                } label: {
                    Label(trackLabel(track), systemImage: track.isSelected ? "checkmark" : "waveform")
                }
            }
        } label: {
            Label(audioMenuLabel, systemImage: "waveform")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.9))
    }

    private var audioMenuLabel: String {
        if let current = engine.audioTracks.first(where: { $0.isSelected }) {
            return "音轨 · \(current.title)"
        }
        return "音轨"
    }

    private func trackLabel(_ track: MediaTrack) -> String {
        guard let detail = track.detail, !detail.isEmpty else { return track.title }
        return "\(track.title)  ·  \(detail)"
    }

    private var subtitleMenu: some View {
        Menu {
            Button("关闭字幕") { clearSubtitles() }

            if !engine.subtitleTracks.isEmpty {
                Divider()
                ForEach(engine.subtitleTracks) { track in
                    Button {
                        pickEmbedded(track)
                    } label: {
                        Label(trackLabel(track),
                              systemImage: track.isSelected ? "checkmark" : "captions.bubble")
                    }
                }
            }

            Divider()
            if subtitleCandidates.isEmpty {
                Text("同目录下没有外挂字幕")
            } else {
                ForEach(subtitleCandidates, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        Task { await selectSubtitle(path) }
                    }
                }
            }

            Divider()
            ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { scale in
                Button(String(format: "字号 %.0f%%", scale * 100)) { prefs.subtitleScale = scale }
            }
        } label: {
            Label(subtitleMenuLabel, systemImage: "captions.bubble")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.9))
    }

    private var subtitleMenuLabel: String {
        if let current = engine.subtitleTracks.first(where: { $0.isSelected }) {
            return "字幕 · \(current.title)"
        }
        return cues.isEmpty ? "字幕" : "字幕 · 外挂"
    }

    /// 选容器里的字幕轨（交给 mpv / AVPlayer 渲染），自己的叠加层要停掉
    private func pickEmbedded(_ track: MediaTrack) {
        selectedSubtitle = nil
        cues = []
        subtitleError = nil
        engine.selectSubtitleTrack(track)
    }

    private func clearSubtitles() {
        selectedSubtitle = nil
        cues = []
        subtitleError = nil
        engine.selectSubtitleTrack(nil)
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                Button(String(format: "%.2fx", r)) {
                    rate = Float(r); engine.setRate(Float(r))
                }
            }
        } label: {
            Label(String(format: "%.2fx", rate), systemImage: "speedometer")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: 字幕

    private var activeCue: SubtitleCue? {
        guard let idx = SubtitleTimeline.activeIndex(in: cues, at: engine.currentTime) else { return nil }
        return cues[idx]
    }

    @ViewBuilder
    private var subtitleOverlay: some View {
        VStack {
            Spacer()
            if let cue = activeCue {
                Text(cue.text)
                    .font(.system(size: 22 * prefs.subtitleScale, weight: .medium))
                    .foregroundStyle(subtitleColor)
                    .shadow(color: .black, radius: prefs.subtitleOutline, x: 0, y: 0)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background {
                        if !prefs.subtitleBackgroundTransparent {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.black.opacity(0.45))
                        }
                    }
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 60)
                    .padding(.bottom, controlsVisible ? prefs.subtitleBottomInset + 60 : prefs.subtitleBottomInset)
                    .animation(.easeOut(duration: 0.12), value: cue.id)
            }
            if let subtitleError {
                Text(subtitleError)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 8)
            }
        }
        .allowsHitTesting(false)
    }

    private func loadSubtitles() async {
        subtitleCandidates = await store.subtitleCandidates(for: item)
        subtitleError = nil
        guard prefs.subtitleAutoLoad, let first = subtitleCandidates.first else { return }
        await selectSubtitle(first)
    }

    private func selectSubtitle(_ path: String) async {
        // 外挂字幕走自己的解析/渲染，容器里的字幕轨要关掉，不然两层字幕叠一起
        engine.disableEmbeddedSubtitles()
        selectedSubtitle = path
        let parsed = await store.subtitleCues(for: item, path: path)
        if parsed.isEmpty {
            subtitleError = "字幕解析失败：\((path as NSString).lastPathComponent)"
            cues = []
        } else {
            subtitleError = nil
            cues = parsed
        }
    }

    // MARK: 行为

    private var subtitleColor: Color {
        switch prefs.subtitleColor {
        case "yellow": return .yellow
        case "cyan":   return .cyan
        default:       return .white
        }
    }

    private func captureScreenshot() {
        guard let target else { return }
        let folder = prefs.resolvedScreenshotFolder
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(title)-\(stamp).\(prefs.screenshotFormat)"
        let url = folder.appendingPathComponent(name)
        let asset = AVURLAsset(url: target.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let time = CMTime(seconds: engine.currentTime, preferredTimescale: 600)
        Task {
            do {
                let cg = try await gen.image(at: time).image
                #if os(macOS)
                let rep = NSBitmapImageRep(cgImage: cg)
                let data = prefs.screenshotFormat == "png"
                    ? rep.representation(using: .png, properties: [:])
                    : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                #else
                let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9)
                #endif
                if let data { try data.write(to: url) }
                withAnimation { shotMessage = "已保存到 \(folder.lastPathComponent)" }
            } catch {
                shotMessage = "截图失败"
            }
        }
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    private func skip(_ delta: Double) {
        engine.seek(to: engine.currentTime + delta)
        withAnimation(.easeOut(duration: 0.1)) {
            seekHint = delta > 0 ? "+\(Int(delta))s" : "\(Int(delta))s"
        }
        seekHintTask?.cancel()
        seekHintTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { seekHint = nil } }
        }
    }

    private func load() async {
        do {
            let t = try await store.playbackTarget(for: item)
            target = t
            let resume = prefs.resumePlayback ? (store.record(for: item.id)?.position ?? 0) : 0
            engine.load(t, startAt: resume)
            rate = Float(prefs.defaultRate)
            if rate != 1.0 { engine.setRate(rate) }
            if prefs.autoMarkWatched, engine.backend == .av,
               let playerItem = engine.player.currentItem {
                playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: playerItem, queue: .main) { _ in
                    Task { @MainActor in
                        if let d = engine.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                            store.record(itemID: item.id, position: d, duration: d)
                        }
                    }
                }
            }
            scheduleHide()
            await loadSubtitles()
            await runTrackProbeIfRequested()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 诊断：容器里放 `track-test.flag` → 播起来 2 秒后自动切到第 2 条音轨 + 第 1 条字幕，日志里核对 aid/sid
    private func runTrackProbeIfRequested() async {
        let flag = StorePaths.root.appendingPathComponent("track-test.flag")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        try? FileManager.default.removeItem(at: flag)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if engine.audioTracks.count > 1 {
            let target = engine.audioTracks[1]
            engine.selectAudio(target)
            try? await Task.sleep(nanoseconds: 700_000_000)
            AppLog.info("TRACK PROBE 切音轨 → \(target.title) aid=\(engine.mpvString("aid") ?? "nil")")
        } else {
            AppLog.info("TRACK PROBE 只有 \(engine.audioTracks.count) 条音轨")
        }
        if let sub = engine.subtitleTracks.first {
            pickEmbedded(sub)
            try? await Task.sleep(nanoseconds: 500_000_000)
            AppLog.info("TRACK PROBE 切字幕 → \(sub.title) sid=\(engine.mpvString("sid") ?? "nil")")
        }
        // 截图核对用：别让控制条自己收起来
        hideTask?.cancel()
        withAnimation { controlsVisible = true }
        AppLog.info("TRACK PROBE 完成 sub-visibility=\(engine.mpvString("sub-visibility") ?? "nil")")
    }

    private func closePlayer() {
        saveProgress()
        store.flushProgressSync()
        engine.stop()
        presenter.close()
    }

    private func saveProgress() {
        let pos = engine.currentTime
        guard pos > 1 else { return }
        let dur = engine.duration > 0 ? engine.duration : max(pos, 1)
        store.record(itemID: item.id, position: pos, duration: dur)
    }

    private func revealControls() {
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.15)) { controlsVisible = true }
        }
        scheduleHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0.5, prefs.autoHideControls) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if engine.isPlaying && !isScrubbing {
                    withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = false }
                }
            }
        }
    }
}

/// 播放器上的半透明圆形按钮
private struct PlayerGlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.12), in: Circle())
            .contentShape(Circle())
    }
}


/// 自绘进度条：DragGesture 直接跟随手指，比系统 Slider 在视频层上可靠
private struct ScrubBar: View {
    let value: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var dragValue: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        let v = dragValue ?? value
        return min(max(v / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                    .frame(height: 4)
                Capsule().fill(.white)
                    .frame(width: max(0, geo.size.width * progress), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, geo.size.width * progress) - 6)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard duration > 0 else { return }
                        let p = min(max(g.location.x / geo.size.width, 0), 1)
                        let v = p * duration
                        dragValue = v
                        onScrub(v)
                    }
                    .onEnded { _ in
                        if let v = dragValue { onCommit(v) }
                        dragValue = nil
                    }
            )
        }
        .frame(height: 18)
    }
}
