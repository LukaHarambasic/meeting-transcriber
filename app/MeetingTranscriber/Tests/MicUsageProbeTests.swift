@testable import MeetingTranscriber
import XCTest

/// The decision half of `MicUsageProbe`. The CoreAudio read cannot be pinned
/// here: which processes hold the microphone on a CI runner is not something a
/// test controls, so only the pure reduction over what was read is asserted.
final class MicUsageProbeTests: XCTestCase {
    private let ownPID: pid_t = 100

    private func entry(_ pid: pid_t, input: Bool) -> MicUsageProbe.ProcessEntry {
        MicUsageProbe.ProcessEntry(pid: pid, isRunningInput: input)
    }

    func testAnotherProcessRunningInputCounts() {
        let entries = [entry(200, input: true), entry(300, input: false)]
        XCTAssertTrue(MicUsageProbe.anyOtherRunningInput(entries, ownPID: ownPID))
    }

    /// Our own recording holds the microphone, so counting it would make every
    /// recording look like a call that never ends.
    func testOwnProcessIsExcluded() {
        let entries = [entry(ownPID, input: true), entry(300, input: false)]
        XCTAssertFalse(MicUsageProbe.anyOtherRunningInput(entries, ownPID: ownPID))
    }

    func testOwnProcessDoesNotHideAnotherOne() {
        let entries = [entry(ownPID, input: true), entry(200, input: true)]
        XCTAssertTrue(MicUsageProbe.anyOtherRunningInput(entries, ownPID: ownPID))
    }

    func testNobodyRunningInputAndAnEmptyListBothReadAsFree() {
        XCTAssertFalse(MicUsageProbe.anyOtherRunningInput([entry(200, input: false)], ownPID: ownPID))
        XCTAssertFalse(MicUsageProbe.anyOtherRunningInput([], ownPID: ownPID))
    }
}
