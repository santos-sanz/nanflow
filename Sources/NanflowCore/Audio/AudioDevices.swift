import CoreAudio
import Foundation

public struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: AudioObjectID
    public let name: String
    public let isDefault: Bool

    public var uid: String? { AudioDevices.deviceUID(for: id) }
    public var uidTag: String { uid ?? "" }
}

/// Enumerates system input devices so the UI can let the user pick a microphone.
public enum AudioDevices {
    public static func inputDevices() -> [AudioDeviceInfo] {
        let defaultID = defaultInputDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var devices: [AudioDeviceInfo] = []
        for id in ids where hasInputStream(id) {
            devices.append(AudioDeviceInfo(id: id, name: deviceName(id) ?? "Mic \(id)", isDefault: id == defaultID))
        }
        return devices
    }

    public static func defaultInputDeviceID() -> AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr {
            return id
        }
        return 0
    }

    /// Resolves a persistent device UID string to an AudioObjectID.
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var translation = AudioDeviceTranslateUIDParams(
            translationType: 0,
            class: 0,
            id: 0,
            uid: uid as CFString
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &translation) { params in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<AudioDeviceTranslateUIDParams>.size),
                params,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    public static func deviceUID(for id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = uid else { return nil }
        return value as String
    }

    private static func hasInputStream(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = name else { return nil }
        return value as String
    }
}

private struct AudioDeviceTranslateUIDParams {
    var translationType: UInt32
    var `class`: UInt32
    var id: UInt32
    var uid: CFString
}
