import Foundation
#if os(macOS)
import CoreAudio

/// 取系统默认输出设备的 UID，给 mpv 的 `audio-device=coreaudio/<uid>` 用，
/// 绕开 mpv 自己枚举设备（枚举在沙盒里会让进程崩）。
enum AudioOutput {
    static func defaultDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        let s = uid as String
        return s.isEmpty ? nil : s
    }
}
#else
enum AudioOutput {
    static func defaultDeviceUID() -> String? { nil }
}
#endif
