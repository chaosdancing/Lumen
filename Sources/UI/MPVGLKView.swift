#if os(iOS)
import SwiftUI
import UIKit
import OpenGLES
import QuartzCore

/// iOS 端的 mpv 画面宿主：CAEAGLLayer + OpenGL ES 3.0 + render API。
/// mpv 只负责解码，帧由我们自己的 GL 上下文画到 renderbuffer 上。
final class MPVGLKView: UIView, MPVRenderHost {
    weak var core: PlayerCore?

    private var context: EAGLContext?
    private var framebuffer: GLuint = 0
    private var colorRenderbuffer: GLuint = 0
    private var renderContext: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var attached = false
    private var drawableWidth: GLint = 0
    private var drawableHeight: GLint = 0
    private var allocatedSize: CGSize = .zero

    private final class DisplayLinkTarget: NSObject {
        weak var view: MPVGLKView?
        @objc func tick() { view?.tick() }
    }
    private let displayLinkTarget = DisplayLinkTarget()

    var renderContextReady: Bool { renderContext != nil }

    override class var layerClass: AnyClass { CAEAGLLayer.self }
    private var eaglLayer: CAEAGLLayer { layer as! CAEAGLLayer }

    init(core: PlayerCore) {
        super.init(frame: .zero)
        self.core = core
        backgroundColor = .black
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]
        setupContext()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: GL 环境

    private func setupContext() {
        guard let ctx = EAGLContext(api: .openGLES3) else {
            AppLog.error("EAGLContext 创建失败")
            return
        }
        context = ctx
        EAGLContext.setCurrent(ctx)
        contentScaleFactor = UIScreen.main.scale
        AppLog.info("iOS GL 环境就绪（EAGLContext ES3）")
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        displayLinkTarget.view = self
        let link = CADisplayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private var renderCount = 0

    @objc private func tick() {
        guard let rctx = renderContext else { return }
        EAGLContext.setCurrent(context)
        // MPV_RENDER_UPDATE_FRAME = 1：有新帧就标脏
        if mpv_render_context_update(rctx) & 1 != 0 { needsRender = true }
        guard needsRender else { return }
        needsRender = false
        render()
    }

    // MARK: render API

    func createRenderContext(mpv: OpaquePointer) -> Bool {
        guard let ctx = context else { return false }
        EAGLContext.setCurrent(ctx)

        var initParams = MPVOpenGLInitParams(
            getProcAddress: { _, name in
                guard let name else { return nil }
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
            AppLog.error("iOS mpv_render_context_create 失败 rc=\(rc)")
            return false
        }
        renderContext = created

        // CADisplayLink polls update on the GL thread; no unretained cross-thread callback.
        startDisplayLink()
        AppLog.info("iOS mpv render context 创建成功（opengl es）")
        needsRender = true
        return true
    }

    private func render() {
        guard let renderContext, let ctx = context else { return }
        EAGLContext.setCurrent(ctx)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

        let w = drawableWidth
        let h = drawableHeight
        guard w > 0, h > 0 else { return }

        var fbo = MPVOpenGLFBO(fbo: GLint(framebuffer), w: w, h: h, internalFormat: 0)
        var flip: Int32 = 1
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPtr in
                var params = [
                    MPVRenderParam(type: MPVRenderParamType.openGLFBO,
                                   data: UnsafeMutableRawPointer(fboPtr)),
                    MPVRenderParam(type: MPVRenderParamType.flipY,
                                   data: UnsafeMutableRawPointer(flipPtr)),
                    // CADisplayLink 已负责帧调度，不能让 mpv 在主线程等下一帧时间。
                    MPVRenderParam(type: MPVRenderParamType.blockForTargetTime,
                                   data: UnsafeMutableRawPointer(blockPtr)),
                    MPVRenderParam(type: MPVRenderParamType.invalid, data: nil)
                ]
                let rc = mpv_render_context_render(renderContext, &params)
                if rc < 0 { AppLog.error("iOS render rc=\(rc)") }
                }
            }
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        if !ctx.presentRenderbuffer(Int(GL_RENDERBUFFER)) {
            AppLog.error("iOS presentRenderbuffer 失败")
        }

        renderCount += 1
        if renderCount == 1 || renderCount == 60 {
            AppLog.info("iOS 已渲染 \(renderCount) 帧（\(w)x\(h)）")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let ctx = context else { return }
        let pixelSize = CGSize(width: bounds.width * contentScaleFactor,
                               height: bounds.height * contentScaleFactor)
        // 进度/控制条更新也会触发布局，尺寸未变时不能重新分配并清空画面。
        guard pixelSize != allocatedSize || framebuffer == 0 else { return }
        EAGLContext.setCurrent(ctx)

        if framebuffer == 0 {
            glGenFramebuffers(1, &framebuffer)
            glGenRenderbuffers(1, &colorRenderbuffer)
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        guard ctx.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer) else { return }
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &drawableWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &drawableHeight)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                  GLenum(GL_RENDERBUFFER), colorRenderbuffer)

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            AppLog.error("framebuffer 不完整 status=\(status) bounds=\(Int(bounds.width))x\(Int(bounds.height))")
            return
        }
        allocatedSize = pixelSize
        if !attached {
            attached = true
            AppLog.info("iOS framebuffer 就绪 \(Int(bounds.width * contentScaleFactor))x\(Int(bounds.height * contentScaleFactor))")
            core?.attachRenderHost(self)
        }
        needsRender = true
    }

    func destroyRenderContext() {
        displayLink?.invalidate()
        displayLink = nil
        guard let ctx = renderContext else { return }
        EAGLContext.setCurrent(context)
        renderContext = nil
        mpv_render_context_free(ctx)
    }

    func tearDown() {
        destroyRenderContext()
        EAGLContext.setCurrent(context)
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer); framebuffer = 0 }
        if colorRenderbuffer != 0 { glDeleteRenderbuffers(1, &colorRenderbuffer); colorRenderbuffer = 0 }
        attached = false
        allocatedSize = .zero
    }

    deinit {
        displayLink?.invalidate()
        destroyRenderContext()
    }
}

struct MPVSurfaceiOS: UIViewRepresentable {
    let core: PlayerCore

    func makeUIView(context: Context) -> MPVGLKView {
        MPVGLKView(core: core)
    }

    func updateUIView(_ uiView: MPVGLKView, context: Context) {
        uiView.core = core
    }

    static func dismantleUIView(_ uiView: MPVGLKView, coordinator: ()) {
        uiView.tearDown()
    }
}
#endif
