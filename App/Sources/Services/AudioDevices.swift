import AppKit
import CoreAudio
import Foundation

/// The microphones on this Mac, and which one Chirp should use.
enum AudioDevices {
    /// One microphone, with the identifier that stays the same across restarts.
    struct Input: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// The microphone the user picked, by its permanent identifier. Empty means "whatever macOS is using".
    static var preferredUID: String {
        get { UserDefaults.standard.string(forKey: "microphoneUID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "microphoneUID") }
    }

    /// Every connected device that can record.
    static func inputs() -> [Input] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = SystemAudioTap.stringProperty(id, kAudioDevicePropertyDeviceUID),
                let name = SystemAudioTap.stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return Input(uid: uid, name: name)
        }
    }

    /// The device to record from: the chosen one if it is connected, otherwise the system's.
    static func recordingDevice() -> AudioDeviceID? {
        let wanted = preferredUID
        if !wanted.isEmpty,
            let match = deviceIDs().first(where: { hasInput($0) && SystemAudioTap.stringProperty($0, kAudioDevicePropertyDeviceUID) == wanted })
        {
            return match
        }
        return defaultInput()
    }

    /// The device's name as macOS shows it.
    static func name(of id: AudioDeviceID) -> String { SystemAudioTap.stringProperty(id, kAudioObjectPropertyName) ?? "?" }

    /// Every audio device macOS knows about, input or output.
    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Whether the device has anything to record from.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// The microphone macOS is set to use.
    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }
}

extension AudioDevices {
    /// Whether everything that is playing sound right now is going to headphones, so that none of it can
    /// reach the microphone. With nothing playing, the Mac's chosen output decides. Chirp's own sound is
    /// not counted. A call app may
    /// play through a device other than the chosen one, so every device in use is looked at.
    static func outputsAreHeadphones() -> Bool {
        let playing = devicesOtherAppsPlayThrough()
        if playing.isEmpty { return defaultOutput().map(isHeadphones) ?? false }
        return playing.allSatisfy(isHeadphones)
    }

    /// Whether an output device sits on or in the ears. First what the device says its sockets are; then,
    /// its kind and name: a Bluetooth device unless its name is a loudspeaker's, a USB
    /// device named as a headset, the built-in output when it is the headphone socket.
    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        // 'hdph' headphones, 'hmic' a headset; 0x0302 and 0x0304 are the USB codes for headphones and a head-mounted display.
        let onEars: Set<UInt32> = [kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeHeadsetMicrophone, 0x0302, 0x0304]
        if outputStreams(of: device).contains(where: { uint32($0, kAudioStreamPropertyTerminalType).map(onEars.contains) ?? false }) { return true }
        let name = name(of: device).lowercased()
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return !["speaker", "soundbar", "sound bar", "soundlink", "boombox", "homepod", "sonos", "megaboom", "wonderboom", "jbl flip", "jbl charge", "jbl clip", "jbl go"]
                .contains(where: name.contains)
        case kAudioDeviceTransportTypeUSB:
            return ["headphone", "headset", "airpod", "earbud"].contains(where: name.contains)
        case kAudioDeviceTransportTypeBuiltIn:
            return name.contains("headphone")
        default:
            return false
        }
    }

    /// The output devices other apps have sound running through.
    static func devicesOtherAppsPlayThrough() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var found = Set<AudioDeviceID>()
        for process in objects(AudioObjectID(kAudioObjectSystemObject), &address) {
            // A process whose id cannot be read is left out: counting Chirp itself would be the worse mistake.
            guard let pid = uint32(process, kAudioProcessPropertyPID), pid_t(pid) != getpid(),
                uint32(process, kAudioProcessPropertyIsRunningOutput) == 1
            else { continue }
            var devices = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            found.formUnion(objects(process, &devices))
        }
        // Capture devices made for taps (Chirp's own, another recorder's) play nothing anyone hears.
        return found.filter { uint32($0, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate }
    }

    /// The device the Mac is set to play through.
    static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func outputStreams(of device: AudioDeviceID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return objects(device, &address)
    }

    /// A list of audio objects held in one property of another.
    private static func objects(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> [AudioObjectID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// A number held in one property of an audio object.
    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}

/// The short sounds that say dictation started and stopped.
@MainActor
enum Sounds {
    /// Whether the start and stop sounds play.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dictationSounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dictationSounds") }
    }

    static func start() { play("Tink") }
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard enabled, !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        NSSound(named: name)?.play()
    }
}
