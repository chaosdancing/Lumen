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
        startDisplayLink()
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
        eaglLayer.contentsScale = UIScreen.main.scale
        AppLog.info("iOS GL 环境就绪（EAGLContext ES3）")
    }

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private var renderCount = 0

    @objc private func tick() {
        guard let rctx = renderContext else { return }
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

        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVGLKView>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { view.needsRender = true }
        }
        mpv_render_context_set_update_callback(created, callback,
                                               Unmanaged.passUnretained(self).toOpaque())
        AppLog.info("iOS mpv render context 创建成功（opengl es）")
        needsRender = true
        return true
    }

    private func render() {
        guard let renderContext, let ctx = context else { return }
        EAGLContext.setCurrent(ctx)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)

        let scale = contentScaleFactor
        let w = Int32(bounds.width * scale)
        let h = Int32(bounds.height * scale)
        guard w > 0, h > 0 else { return }

        var fbo = MPVOpenGLFBO(fbo: GLint(framebuffer), w: w, h: h, internalFormat: 0)
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
                if rc < 0 { AppLog.error("iOS render rc=\(rc)") }
            }
        }
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        ctx.presentRenderbuffer(Int(GL_RENDERBUFFER))

        renderCount += 1
        if renderCount == 1 || renderCount == 60 {
            AppLog.info("iOS 已渲染 \(renderCount) 帧（\(w)x\(h)）")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let ctx = context else { return }
        EAGLContext.setCurrent(ctx)

        if framebuffer == 0 {
            glGenFramebuffers(1, &framebuffer)
            glGenRenderbuffers(1, &colorRenderbuffer)
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
        ctx.renderbufferStorage(Int(GL_RENDERBUFFER), from: eaglLayer)
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
                                  GLenum(GL_RENDERBUFFER), colorRenderbuffer)

        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            AppLog.error("framebuffer 不完整 status=\(status) bounds=\(Int(bounds.width))x\(Int(bounds.height))")
            return
        }
        if !attached {
            attached = true
            AppLog.info("iOS framebuffer 就绪 \(Int(bounds.width * contentScaleFactor))x\(Int(bounds.height * contentScaleFactor))")
            core?.attachRenderHost(self)
        }
        needsRender = true
    }

    func destroyRenderContext() {
        guard let ctx = renderContext else { return }
        renderContext = nil
        displayLink?.invalidate()
        displayLink = nil
        mpv_render_context_free(ctx)
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
}
#endif
