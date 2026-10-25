import SwiftUI
#if os(macOS)
import AppKit
import OpenGL.GL3

/// mpv render API 的显示层：mpv 只负责解码，帧由我们自己的 OpenGL 上下文画出来。
/// 这跟 MediaCenter（VidHub）的做法一致 —— `--wid` 让 mpv 自己建图层在沙盒 + Metal 下会崩。
final class MPVGLView: NSOpenGLView, MPVRenderHost {
    weak var core: PlayerCore?
    private var renderContext: OpaquePointer?
    private var didSetup = false
    private var renderedFrames = 0
    var renderContextReady: Bool { renderContext != nil }

    init(core: PlayerCore) {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)
        super.init(frame: .zero, pixelFormat: format)!
        self.core = core
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 初始化

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard !didSetup else { return }
        didSetup = true
        var swap: Int32 = 1
        openGLContext?.setValues(&swap, for: .swapInterval)
        AppLog.info("GL 上下文就绪，准备创建 mpv render context")
        core?.attachRenderHost(self)
    }

    /// 由 PlayerCore 在 mpv 初始化完成后调用
    func createRenderContext(mpv: OpaquePointer) -> Bool {
        guard let gl = openGLContext else {
            AppLog.error("没有 GL 上下文")
            return false
        }
        gl.makeCurrentContext()

        var initParams = MPVOpenGLInitParams(
            getProcAddress: { _, name in
                guard let name else { return nil }
                // RTLD_DEFAULT = (void *)-2
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            },
            getProcAddressCtx: nil
        )

        var created: OpaquePointer?
        let rc: Int32 = withUnsafeMutablePointer(to: &initParams) { initPtr in
            "opengl".withCString { apiPtr in
                var params = [
                    MPVRenderParam(type: MPVRenderParamType.apiType,
                                   data: UnsafeMutableRawPointer(mutating: apiPtr)),
                    MPVRenderParam(type: MPVRenderParamType.openGLInitParams,
                                   data: UnsafeMutableRawPointer(initPtr)),
                    MPVRenderParam(type: MPVRenderParamType.invalid, data: nil)
                ]
                return mpv_render_context_create(&created, mpv, &params)
            }
        }
        guard rc >= 0, let created else {
            AppLog.error("mpv_render_context_create 失败 rc=\(rc)")
            return false
        }
        renderContext = created

        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVGLView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                view.needsDisplay = true
            }
        }
        mpv_render_context_set_update_callback(created, callback,
                                               Unmanaged.passUnretained(self).toOpaque())
        AppLog.info("mpv render context 创建成功（opengl）")
        needsDisplay = true
        return true
    }

    // MARK: 绘制

    /// 不拦截鼠标：交互由 PlayerWindowController 的本地事件监听统一处理
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        render()
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    private func render() {
        guard let renderContext, let gl = openGLContext else { return }
        gl.makeCurrentContext()

        let backing = convertToBacking(bounds)
        guard backing.width > 0, backing.height > 0 else { return }

        var fbo = MPVOpenGLFBO(fbo: 0,
                               w: Int32(backing.width),
                               h: Int32(backing.height),
                               internalFormat: 0)
        var flip: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    MPVRenderParam(type: MPVRenderParamType.openGLFBO,
                                   data: UnsafeMutableRawPointer(fboPtr)),
                    MPVRenderParam(type: MPVRenderParamType.flipY,
                                   data: UnsafeMutableRawPointer(flipPtr)),
                    MPVRenderParam(type: MPVRenderParamType.invalid, data: nil)
                ]
                let rc = mpv_render_context_render(renderContext, &params)
                if rc < 0 {
                    AppLog.error("mpv_render_context_render rc=\(rc)")
                } else {
                    renderedFrames += 1
                    if renderedFrames == 1 || renderedFrames == 30 {
                        AppLog.info("mpv 已渲染 \(renderedFrames) 帧（\(Int(backing.width))x\(Int(backing.height))）")
                    }
                }
            }
        }
        gl.flushBuffer()
    }

    func destroyRenderContext() {
        guard let ctx = renderContext else { return }
        renderContext = nil
        mpv_render_context_free(ctx)
    }

    deinit { destroyRenderContext() }
}
#endif
