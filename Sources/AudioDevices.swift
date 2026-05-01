import AudioToolbox
import CoreAudio
import Foundation

/// Discoverable handle to one CoreAudio device. The `id` is the
/// `AudioDeviceID` we hand to `AudioUnitSetProperty
/// (kAudioOutputUnitProperty_CurrentDevice…)` to bind an AVAudioEngine
/// node to a specific physical or virtual device.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

/// CoreAudio device enumeration + system-default helpers. Used by
/// `MicCapture` to bind the AVAudioEngine input/output nodes to the
/// user-selected device, and by the menubar UI to populate pickers.
enum AudioDevices {
    /// All known input + output devices on the system. Repeated calls
    /// are cheap (a couple of HAL property reads); call on every
    /// menubar-popover open to pick up hot-plug changes.
    static func all() -> [AudioDevice] {
        deviceIDs().compactMap(makeDevice)
    }

    static func inputs() -> [AudioDevice] {
        all().filter { $0.hasInput }
    }

    static func outputs() -> [AudioDevice] {
        all().filter { $0.hasOutput }
    }

    /// Default-input device (system-wide).
    static func defaultInputID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Default-output device (system-wide).
    static func defaultOutputID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Apply a device to an AVAudioEngine input or output node. Pass
    /// the node's audioUnit handle. Engine must be stopped before
    /// this — switching device requires a fresh render-graph
    /// negotiation. Returns the OSStatus from
    /// `AudioUnitSetProperty`; `noErr` on success.
    @discardableResult
    static func bind(deviceID: AudioDeviceID, to audioUnit: AudioUnit) -> OSStatus {
        var id = deviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    // MARK: - HAL helpers

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            var sz = size
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, base
            )
        }
        guard status == noErr else { return [] }
        return ids
    }

    private static func makeDevice(id: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName),
              let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID)
        else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            hasInput: hasStreams(deviceID: id, scope: kAudioObjectPropertyScopeInput),
            hasOutput: hasStreams(deviceID: id, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    /// True if the device has any streams in the given scope. Filters
    /// e.g. Bluetooth A2DP devices that show up in both lists but only
    /// have output streams when paired in headphone-only mode.
    private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr else { return false }
        return size > 0
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
