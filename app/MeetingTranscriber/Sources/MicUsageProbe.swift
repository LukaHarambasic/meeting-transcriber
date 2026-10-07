import CoreAudio
import Foundation

/// Answers "is any process other than this app capturing from an input device
/// right now?" from CoreAudio's per-process audio objects (macOS 14.2+).
///
/// Each process that has talked to the audio system owns a process object with
/// a pid and an "is running input" flag. Reading them needs no permission, and
/// opens no device: unlike a live microphone probe it cannot disturb a
/// Bluetooth headset, which is why it may run every few seconds for the length
/// of a meeting.
///
/// This app's own pid is excluded, because a recording that captures the
/// microphone is itself a process running input.
enum MicUsageProbe {
    /// One CoreAudio process object, reduced to what the decision reads.
    struct ProcessEntry: Equatable {
        let pid: pid_t
        let isRunningInput: Bool
    }

    /// The process list could not be read at all.
    struct ReadError: Error {}

    /// Production entry point, shaped like the closure `WatchLoop` takes.
    /// `.unknown` when the process list itself could not be read; see
    /// `CallEndPolicy` for why that must count as "no evidence".
    static func currentUsage(ownPID: pid_t = getpid()) -> MicUsage {
        guard let entries = try? readProcessEntries() else { return .unknown }
        return anyOtherRunningInput(entries, ownPID: ownPID) ? .held : .free
    }

    /// The decision, apart from the system calls so it can be asserted directly.
    static func anyOtherRunningInput(_ entries: [ProcessEntry], ownPID: pid_t) -> Bool {
        entries.contains { $0.pid != ownPID && $0.isRunningInput }
    }

    /// Every process object CoreAudio lists, or throws if the list cannot be read.
    ///
    /// An object whose own properties cannot be read is skipped rather than
    /// failing the whole read: processes exit between the listing and the
    /// lookup all the time, and one that is gone is not using the microphone.
    static func readProcessEntries() throws -> [ProcessEntry] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { throw ReadError() }
        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size,
        )
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects) == noErr else { throw ReadError() }
        let filled = Int(size) / MemoryLayout<AudioObjectID>.size
        return objects.prefix(filled).compactMap(entry(for:))
    }

    private static func entry(for object: AudioObjectID) -> ProcessEntry? {
        guard let pid: pid_t = readValue(of: object, selector: kAudioProcessPropertyPID),
              let running: UInt32 = readValue(of: object, selector: kAudioProcessPropertyIsRunningInput)
        else { return nil }
        return ProcessEntry(pid: pid, isRunningInput: running != 0)
    }

    private static func readValue<T: FixedWidthInteger>(
        of object: AudioObjectID,
        selector: AudioObjectPropertySelector,
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
