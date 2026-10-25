import Foundation

/// 全局偏好。键名参考 VidHub 的 `Preferences.Playback.*` 结构，
/// 但只保留我们能真正生效的项 —— 需要 mpv 内核的（硬解/隔行/独显/磁盘缓存）单独标注。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let d = UserDefaults.standard

    // MARK: 播放
    @Published var autoHideControls: Double { didSet { d.set(autoHideControls, forKey: "pb.autoHide") } }
    @Published var defaultRate: Double { didSet { d.set(defaultRate, forKey: "pb.rate") } }
    @Published var doubleClickPause: Bool { didSet { d.set(doubleClickPause, forKey: "pb.dblclick") } }
    @Published var resumePlayback: Bool { didSet { d.set(resumePlayback, forKey: "pb.resume") } }
    @Published var autoMarkWatched: Bool { didSet { d.set(autoMarkWatched, forKey: "pb.automark") } }
    @Published var forwardInterval: Double { didSet { d.set(forwardInterval, forKey: "pb.forward") } }
    @Published var rewindInterval: Double { didSet { d.set(rewindInterval, forKey: "pb.rewind") } }
    @Published var pauseOnMinimize: Bool { didSet { d.set(pauseOnMinimize, forKey: "pb.pausemin") } }

    // MARK: 字幕
    @Published var subtitleScale: Double { didSet { d.set(subtitleScale, forKey: "sub.scale") } }
    @Published var subtitleColor: String { didSet { d.set(subtitleColor, forKey: "sub.color") } }
    @Published var subtitleOutline: Double { didSet { d.set(subtitleOutline, forKey: "sub.outline") } }
    @Published var subtitleBottomInset: Double { didSet { d.set(subtitleBottomInset, forKey: "sub.inset") } }
    @Published var subtitleAutoLoad: Bool { didSet { d.set(subtitleAutoLoad, forKey: "sub.autoload") } }

    // MARK: 截图
    @Published var screenshotFormat: String { didSet { d.set(screenshotFormat, forKey: "shot.format") } }
    @Published var screenshotFolder: String { didSet { d.set(screenshotFolder, forKey: "shot.folder") } }

    // MARK: 外观 / 通用（对齐 VidHub「通用」页）
    @Published var showCarousel: Bool { didSet { d.set(showCarousel, forKey: "ui.carousel") } }
    @Published var hideSpoilers: Bool { didSet { d.set(hideSpoilers, forKey: "ui.spoiler") } }
    @Published var showRatings: Bool { didSet { d.set(showRatings, forKey: "ui.ratings") } }
    @Published var showMoreRatings: Bool { didSet { d.set(showMoreRatings, forKey: "ui.moreRatings") } }
    @Published var defaultSort: String { didSet { d.set(defaultSort, forKey: "ui.sort") } }
    @Published var appearance: String { didSet { d.set(appearance, forKey: "ui.appearance") } }
    @Published var preferLocalPoster: Bool { didSet { d.set(preferLocalPoster, forKey: "meta.localPoster") } }
    @Published var preferNFO: Bool { didSet { d.set(preferNFO, forKey: "meta.preferNFO") } }
    @Published var posterColumns: Int { didSet { d.set(posterColumns, forKey: "ui.columns") } }

    private init() {
        autoHideControls = d.object(forKey: "pb.autoHide") as? Double ?? 3.5
        defaultRate = d.object(forKey: "pb.rate") as? Double ?? 1.0
        doubleClickPause = d.object(forKey: "pb.dblclick") as? Bool ?? true
        resumePlayback = d.object(forKey: "pb.resume") as? Bool ?? true
        autoMarkWatched = d.object(forKey: "pb.automark") as? Bool ?? true
        forwardInterval = d.object(forKey: "pb.forward") as? Double ?? 10
        rewindInterval = d.object(forKey: "pb.rewind") as? Double ?? 10
        pauseOnMinimize = d.object(forKey: "pb.pausemin") as? Bool ?? false

        subtitleScale = d.object(forKey: "sub.scale") as? Double ?? 1.0
        subtitleColor = d.string(forKey: "sub.color") ?? "white"
        subtitleOutline = d.object(forKey: "sub.outline") as? Double ?? 2.0
        subtitleBottomInset = d.object(forKey: "sub.inset") as? Double ?? 58
        subtitleAutoLoad = d.object(forKey: "sub.autoload") as? Bool ?? true

        screenshotFormat = d.string(forKey: "shot.format") ?? "jpg"
        screenshotFolder = d.string(forKey: "shot.folder") ?? ""

        posterColumns = d.object(forKey: "ui.columns") as? Int ?? 0
        showCarousel = d.object(forKey: "ui.carousel") as? Bool ?? true
        hideSpoilers = d.object(forKey: "ui.spoiler") as? Bool ?? false
        showRatings = d.object(forKey: "ui.ratings") as? Bool ?? true
        showMoreRatings = d.object(forKey: "ui.moreRatings") as? Bool ?? true
        defaultSort = d.string(forKey: "ui.sort") ?? "added"
        appearance = d.string(forKey: "ui.appearance") ?? "auto"
        preferLocalPoster = d.object(forKey: "meta.localPoster") as? Bool ?? true
        preferNFO = d.object(forKey: "meta.preferNFO") as? Bool ?? true
    }

    var resolvedScreenshotFolder: URL {
        if !screenshotFolder.isEmpty { return URL(fileURLWithPath: screenshotFolder) }
        #if os(macOS)
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            return pictures
        }
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
    }
}
