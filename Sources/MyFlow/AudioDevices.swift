import Foundation
import CoreAudio

enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyIsHidden)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return false }
        return v == 1
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard st == noErr, let cf else { return "Device \(id)" }
        return cf.takeRetainedValue() as String
    }

    static func inputs() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter { hasInput($0) && !isHidden($0) }.map { Device(id: $0, name: name($0)) }
    }

    static func defaultInputID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefaultInput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = id
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        if st != noErr { NSLog("setDefaultInput failed: \(st)") }
    }
}
