import Foundation
import CoreAudio

/// Mutes the default output device while recording so background media
/// (YouTube, music) keeps playing but is silenced — then restores it.
enum AudioDucking {
    private static var previousMute: UInt32?
    /// CoreAudio property writes can block for tens of milliseconds. They are
    /// never on the keypress path — a serial queue keeps duck/unduck ordered.
    private static let queue = DispatchQueue(label: "myflow.ducking")

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func duck() {
        let enabled = AppSettings.shared.muteWhileRecording
        queue.async { duckNow(enabled: enabled) }
    }

    static func unduck() {
        queue.async { unduckNow() }
    }

    private static func duckNow(enabled: Bool) {
        guard enabled,
              let dev = defaultOutputDevice() else { return }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return }
        // remember current state
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &current) == noErr {
            previousMute = current
        }
        var mute: UInt32 = 1
        AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    private static func unduckNow() {
        guard let dev = defaultOutputDevice() else { previousMute = nil; return }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { previousMute = nil; return }
        var restore = previousMute ?? 0   // default: unmuted
        AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &restore)
        previousMute = nil
    }
}
