#if os(macOS)
import AppKit
import SwiftUI

/// 播放器独立窗口。
/// 之前用 `.sheet` 呈现，导致：窗口不能拉大、全屏无效（keyWindow 是主窗口）、关闭后不停止播放。
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    private var window: NSWindow?
    private var onClose: (() -> Void)?
    /// 由 PlayerView 注入
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var monitor: Any?
    private var pendingSingle: DispatchWorkItem?

    /// 底部控制条高度：这块区域交给 SwiftUI 按钮
    private let controlsHeight: CGFloat = 110

    func show<Content: View>(_ content: Content, title: String, onClose: @escaping () -> Void) {
        close()

        let hosting = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.title = title
        win.identifier = NSUserInterfaceItemIdentifier("player")
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .black
        // 播放器永远是深色界面：跟系统/App 外观无关，
        // 否则浅色模式下「字幕 / 速率」这类 Menu 会拿到黑色标签，压在黑底上直接看不见
        win.appearance = NSAppearance(named: .darkAqua)
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 480, height: 270)
        win.setContentSize(NSSize(width: 1280, height: 720))
        win.collectionBehavior = [.fullScreenPrimary]
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)

        self.window = win
        self.onClose = onClose
        installEventMonitor()
        AppLog.info("播放器窗口已打开 \(Int(win.frame.width))x\(Int(win.frame.height))")
    }

    /// 本地监听：在事件分发到视图之前拦截，绕开 NSView/SwiftUI 的层级问题
    private func installEventMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self, let win = self.window, event.window === win else { return event }
            let point = event.locationInWindow
            let inControls = point.y < self.controlsHeight

            if event.type == .leftMouseDragged {
                // 画面区域任意位置拖动窗口
                guard !inControls else { return event }
                win.performDrag(with: event)
                return nil
            }

            guard !inControls else { return event }   // 控制条交给 SwiftUI

            if event.clickCount >= 2 {
                self.pendingSingle?.cancel()
                self.pendingSingle = nil
                AppLog.info("播放器：双击 → 全屏切换")
                self.onDoubleClick?()
                return nil          // 吞掉，避免下层视图也收到双击
            }

            // 单击**不拦截**：让中间播放按钮、字幕按钮等照常工作；
            // 同时唤出控制层（点空白处也能让控制条浮出来）。
            self.onSingleClick?()
            return event
        }
    }

    private func removeMonitor() {
        pendingSingle?.cancel()
        pendingSingle = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func close() {
        removeMonitor()
        onSingleClick = nil
        onDoubleClick = nil
        guard let window else { return }
        self.window = nil
        onClose = nil
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitor()
        onSingleClick = nil
        onDoubleClick = nil
        let handler = onClose
        window = nil
        onClose = nil
        handler?()
    }

    /// 全屏切换（播放器窗口自己处理，不能用 NSApp.keyWindow 猜）
    func toggleFullScreen() {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.toggleFullScreen(nil)
    }

    var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }
}
#endif
