import CoreAudio

func caCheck(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw NSError(domain: "iQualize", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(message): OSStatus \(status)"])
    }
}

func getDefaultOutputDeviceID() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try caCheck(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &deviceID),
        "Failed to get default output device"
    )
    return deviceID
}

/// Returns whether Core Audio currently reports the device as alive. This is
/// the same readiness signal used by the capture helper while its aggregate
/// device comes online.
func isAudioDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var alive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
        deviceID, &address, 0, nil, &size, &alive
    )
    return status == noErr && alive != 0
}

/// Readiness check used by wake recovery. It deliberately does not introduce
/// another fixed delay. The lifecycle coordinator polls this condition with a
/// bounded deadline and starts only after the default output is alive.
func isDefaultOutputDeviceReady() -> Bool {
    guard let deviceID = try? getDefaultOutputDeviceID() else { return false }
    return isAudioDeviceAlive(deviceID)
}

// CoreAudio returns a +1 CFString for the UID/name selectors. Reading it into a
// `var uid: CFString` and passing `&uid` forms a raw pointer to a variable that
// holds an object reference — the compiler warns, and it leaks the retain.
// Reading into an `Unmanaged` and consuming it with takeRetainedValue is the
// correct ownership transfer.
private func getCFStringProperty(
    _ deviceID: AudioDeviceID,
    _ selector: AudioObjectPropertySelector,
    _ message: String
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value),
        message
    )
    guard let value else {
        throw NSError(domain: "iQualize", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "\(message): no value returned"])
    }
    return value.takeRetainedValue() as String
}

func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
    try getCFStringProperty(deviceID, kAudioDevicePropertyDeviceUID, "Failed to get device UID")
}

func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
    try getCFStringProperty(deviceID, kAudioObjectPropertyName, "Failed to get device name")
}

func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var sampleRate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate),
        "Failed to get device nominal sample rate"
    )
    return sampleRate
}

func getDeviceOutputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
    try getDeviceChannelCount(deviceID, scope: kAudioDevicePropertyScopeOutput)
}

/// Total channels across the device's streams in `scope` (input or output).
func getDeviceChannelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "Failed to get device output stream configuration size"
    )
    let bufferListPointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }
    try caCheck(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer),
        "Failed to get device output stream configuration"
    )
    let bufferList = UnsafeMutableAudioBufferListPointer(
        bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    )
    return bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
}

func getDefaultOutputDevice() throws -> CoreAudioOutputDevice {
    let deviceID = try getDefaultOutputDeviceID()
    return CoreAudioOutputDevice(
        id: deviceID,
        name: try getDeviceName(deviceID),
        uid: try? getDeviceUID(deviceID),
        nominalSampleRate: try? getDeviceNominalSampleRate(deviceID),
        outputChannelCount: try? getDeviceOutputChannelCount(deviceID)
    )
}

// MARK: - Input devices (Room Correction)

/// Every audio device Core Audio currently lists.
func getAllAudioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown),
                              count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func getDefaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &address, 0, nil, &size, &deviceID)
    return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
}

/// `kAudioDeviceTransportType*` for the device (built-in, USB, Bluetooth, …), if known.
func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
    return transport
}

/// The active data source in `scope` (e.g. `'hdpn'` when built-in output is on headphones).
func getDeviceDataSource(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var source: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr else { return nil }
    return source
}

/// A microphone Room Correction can record from.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32?
    let isDefault: Bool

    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    /// An iPhone used as a microphone through Continuity.
    var isContinuity: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Devices with at least one input channel, default first, then by name. Aggregate and
/// virtual devices are left out: a measurement needs a real microphone.
func listAudioInputDevices() -> [AudioInputDevice] {
    let defaultID = getDefaultInputDeviceID()
    return getAllAudioDeviceIDs()
        .compactMap { id -> AudioInputDevice? in
            guard let channels = try? getDeviceChannelCount(id, scope: kAudioDevicePropertyScopeInput),
                  channels > 0,
                  let uid = try? getDeviceUID(id),
                  let name = try? getDeviceName(id) else { return nil }
            let transport = getDeviceTransportType(id)
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual {
                return nil
            }
            return AudioInputDevice(id: id, uid: uid, name: name, transportType: transport, isDefault: id == defaultID)
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
}

/// Why the current output is a poor fit for room correction, if it is: headphones and
/// Bluetooth headsets aren't speakers in a room.
func roomCorrectionOutputWarning(for deviceID: AudioDeviceID) -> String? {
    let transport = getDeviceTransportType(deviceID)
    if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
        return "This output is a Bluetooth device. If it's headphones, room correction won't help — "
            + "use the Preset Browser's OPRA tab for a headphone correction instead."
    }
    // 'hdpn': the built-in output's headphone jack.
    if transport == kAudioDeviceTransportTypeBuiltIn,
       getDeviceDataSource(deviceID, scope: kAudioDevicePropertyScopeOutput) == 0x6864_706E {
        return "The output is the headphone jack. Room correction is for speakers — for headphones, "
            + "use the Preset Browser's OPRA tab instead."
    }
    return nil
}
