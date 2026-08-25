@testable import MeetingTranscriber
import XCTest

@MainActor
final class MeetingTranscriberAppTests: XCTestCase {
    // MARK: - lastCompletedProtocolPath

    func testLastProtocolPathReturnsLatestJob() {
        let url = URL(fileURLWithPath: "/tmp/protocol.md")
        var job = PipelineJob(
            meetingTitle: "Test",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.protocolPath = url

        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [job])
        XCTAssertEqual(result, url)
    }

    func testLastProtocolPathEmptyJobsReturnsNil() {
        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [])
        XCTAssertNil(result)
    }

    func testLastProtocolPathNoProtocolReturnsNil() {
        let job = PipelineJob(
            meetingTitle: "Test",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [job])
        XCTAssertNil(result)
    }
}
