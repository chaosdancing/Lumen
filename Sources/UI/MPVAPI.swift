#if os(macOS) || os(iOS)
import Foundation

/// MPVKit 的产品只暴露了一个空的 `_MPVKit` C target，`import Libmpv` 拿不到模块。
/// 但 `Libmpv.framework` 里的 C 符号是导出的，所以直接用 `@_silgen_name` 声明，
/// 链接期由 MPVKit 带进来的 framework 解析。
enum MPV {
    static let formatFlag: Int32 = 3
    static let formatDouble: Int32 = 5
    static let eventNone: Int32 = 0
    static let eventEndFile: Int32 = 7
    static let endFileReasonEOF: Int32 = 0
}

/// Layout of libmpv's mpv_event and mpv_event_end_file from client.h.
struct MPVEvent {
    var id: Int32
    var error: Int32
    var replyUserdata: UInt64
    var data: UnsafeMutableRawPointer?
}

struct MPVEndFileEvent {
    var reason: Int32
    var error: Int32
    var playlistEntryID: Int64
    var playlistInsertID: Int64
    var playlistInsertCount: Int32
}

@_silgen_name("mpv_wait_event")
func mpv_wait_event(_ ctx: OpaquePointer, _ timeout: Double) -> UnsafePointer<MPVEvent>?

@_silgen_name("mpv_create")
func mpv_create() -> OpaquePointer?

@_silgen_name("mpv_initialize")
func mpv_initialize(_ ctx: OpaquePointer) -> Int32

@_silgen_name("mpv_terminate_destroy")
func mpv_terminate_destroy(_ ctx: OpaquePointer)

@_silgen_name("mpv_set_option_string")
func mpv_set_option_string(_ ctx: OpaquePointer, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_set_property_string")
func mpv_set_property_string(_ ctx: OpaquePointer, _ name: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_get_property")
func mpv_get_property(_ ctx: OpaquePointer, _ name: UnsafePointer<CChar>, _ format: Int32, _ data: UnsafeMutableRawPointer) -> Int32

@_silgen_name("mpv_command_string")
func mpv_command_string(_ ctx: OpaquePointer, _ args: UnsafePointer<CChar>) -> Int32


@_silgen_name("mpv_free")
func mpv_free(_ data: UnsafeMutableRawPointer?)
#endif

// MARK: - 画面宿主协议（macOS / iOS 各自实现）

/// mpv 的帧由宿主视图自己的 GL 上下文绘制
protocol MPVRenderHost: AnyObject {
    var renderContextReady: Bool { get }
    func createRenderContext(mpv: OpaquePointer) -> Bool
    func destroyRenderContext()
    /// 播放 / 暂停切换时通知宿主调整刷新节奏（iOS 用来降低 CADisplayLink 频率）
    func playbackStateChanged(isPlaying: Bool)
}

extension MPVRenderHost {
    func playbackStateChanged(isPlaying: Bool) {}
}

// MARK: - render API（把 mpv 的帧画到自己的 GL 上下文里）

struct MPVOpenGLInitParams {
    var getProcAddress: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var getProcAddressCtx: UnsafeMutableRawPointer?
}

struct MPVOpenGLFBO {
    var fbo: Int32 = 0
    var w: Int32 = 0
    var h: Int32 = 0
    var internalFormat: Int32 = 0
}

struct MPVRenderParam {
    var type: Int32
    var data: UnsafeMutableRawPointer?
}

/// mpv_render_param_type
enum MPVRenderParamType {
    static let invalid: Int32 = 0
    static let apiType: Int32 = 1
    static let openGLInitParams: Int32 = 2
    static let openGLFBO: Int32 = 3
    static let flipY: Int32 = 4
    static let blockForTargetTime: Int32 = 12
}

@_silgen_name("mpv_render_context_create")
func mpv_render_context_create(_ res: UnsafeMutablePointer<OpaquePointer?>,
                               _ mpv: OpaquePointer,
                               _ params: UnsafeMutablePointer<MPVRenderParam>) -> Int32

@_silgen_name("mpv_render_context_set_update_callback")
func mpv_render_context_set_update_callback(_ ctx: OpaquePointer,
                                            _ callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
                                            _ callbackCtx: UnsafeMutableRawPointer?)

@_silgen_name("mpv_render_context_update")
func mpv_render_context_update(_ ctx: OpaquePointer) -> UInt64

@_silgen_name("mpv_render_context_render")
func mpv_render_context_render(_ ctx: OpaquePointer,
                               _ params: UnsafeMutablePointer<MPVRenderParam>) -> Int32

@_silgen_name("mpv_render_context_free")
func mpv_render_context_free(_ ctx: OpaquePointer)

// MARK: - 便捷封装（非 macOS 平台为空实现，保证 iOS 能编译）

#if os(macOS) || os(iOS)
@discardableResult
func mpvSetOption(_ ctx: OpaquePointer, _ name: String, _ value: String) -> Int32 {
    name.withCString { n in value.withCString { v in mpv_set_option_string(ctx, n, v) } }
}

@discardableResult
func mpvSetProperty(_ ctx: OpaquePointer, _ name: String, _ value: String) -> Int32 {
    name.withCString { n in value.withCString { v in mpv_set_property_string(ctx, n, v) } }
}

@discardableResult
func mpvRun(_ ctx: OpaquePointer, _ command: String) -> Int32 {
    command.withCString { c in mpv_command_string(ctx, c) }
}

func mpvGetDouble(_ ctx: OpaquePointer, _ name: String) -> Double? {
    var value: Double = 0
    let rc = name.withCString { n in mpv_get_property(ctx, n, MPV.formatDouble, &value) }
    return rc >= 0 ? value : nil
}

func mpvGetInt(_ ctx: OpaquePointer, _ name: String) -> Int64? {
    var value: Int64 = 0
    let rc = name.withCString { n in mpv_get_property(ctx, n, 4, &value) }
    return rc >= 0 ? value : nil
}

func mpvGetFlag(_ ctx: OpaquePointer, _ name: String) -> Bool? {
    var value: Int32 = 0
    let rc = name.withCString { n in mpv_get_property(ctx, n, MPV.formatFlag, &value) }
    return rc >= 0 ? value != 0 : nil
}

/// MPV_FORMAT_STRING = 1，返回的 C 字符串要用 mpv_free 释放
func mpvGetString(_ ctx: OpaquePointer, _ name: String) -> String? {
    var cstr: UnsafeMutablePointer<CChar>?
    let rc = name.withCString { n in mpv_get_property(ctx, n, 1, &cstr) }
    guard rc >= 0, let cstr else { return nil }
    defer { mpv_free(cstr) }
    let value = String(cString: cstr)
    return value.isEmpty ? nil : value
}
#endif

extension PlayerCore {
    @discardableResult
    func mpvSet(_ name: String, _ value: String) -> Int32 {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return -1 }
        return mpvSetProperty(ctx, name, value)
        #else
        return -1
        #endif
    }

    func mpvCommand(_ command: String) {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return }
        mpvRun(ctx, command)
        #endif
    }

    func mpvDouble(_ name: String) -> Double? {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return nil }
        return mpvGetDouble(ctx, name)
        #else
        return nil
        #endif
    }

    func mpvFlag(_ name: String) -> Bool? {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return nil }
        return mpvGetFlag(ctx, name)
        #else
        return nil
        #endif
    }

    func mpvInt(_ name: String) -> Int64? {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return nil }
        return mpvGetInt(ctx, name)
        #else
        return nil
        #endif
    }

    func mpvString(_ name: String) -> String? {
        #if os(macOS) || os(iOS)
        guard let ctx = mpvHandle else { return nil }
        return mpvGetString(ctx, name)
        #else
        return nil
        #endif
    }
}
