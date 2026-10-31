import CoreAudio
import Foundation

/// Read-only query of the system default input at the moment capture starts.
/// It opens nothing and installs no listener.
enum InputDeviceInfo {
    struct Device: Equatable {
        let name: String
        let isBuiltIn: Bool
    }

    static func current() -> Device? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        let hasTransport = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return Device(name: name.takeRetainedValue() as String,
                      isBuiltIn: hasTransport && transport == kAudioDeviceTransportTypeBuiltIn)
    }
}
