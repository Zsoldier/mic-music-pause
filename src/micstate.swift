import CoreAudio
import Foundation

func prop(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioDeviceID] {
    var addr = prop(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let n = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: n)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}
func hasInput(_ d: AudioDeviceID) -> Bool {
    var addr = prop(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size)
    if size == 0 { return false }
    let bl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
    defer { bl.deallocate() }
    AudioObjectGetPropertyData(d, &addr, 0, nil, &size, bl)
    let abl = UnsafeMutableAudioBufferListPointer(bl)
    var ch = 0
    for b in abl { ch += Int(b.mNumberChannels) }
    return ch > 0
}
func running(_ d: AudioDeviceID) -> Bool {
    var addr = prop(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var r = UInt32(0); var s = UInt32(4)
    AudioObjectGetPropertyData(d, &addr, 0, nil, &s, &r)
    return r != 0
}
let active = devices().contains { hasInput($0) && running($0) }
print(active ? "1" : "0")
