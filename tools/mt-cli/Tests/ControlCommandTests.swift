@testable import mt_cli
import XCTest

/// The `/v1/record` control subcommand.
final class ControlCommandTests: XCTestCase {
    func testCommandNamesItsResource() {
        XCTAssertEqual(Record.resource, "/v1/record")
    }

    func testDefaultsToReadingRatherThanChanging() throws {
        XCTAssertEqual(try Record.parse([]).action, .status)
    }

    func testEveryVerbParses() throws {
        for verb in ControlAction.allCases {
            XCTAssertEqual(try Record.parse([verb.rawValue]).action, verb)
        }
    }

    func testAnUnknownVerbIsRejectedRatherThanTreatedAsAToggle() {
        XCTAssertThrowsError(try Record.parse(["pause"]))
    }

    /// The control route blocks until the start settles, so this bound has to
    /// sit ABOVE the server's own 20 s join. Below it the client gives up first
    /// and reports a failure for a start that then succeeds — the exact thing
    /// the constant exists to prevent, and a one-character edit away.
    func testControlTimeoutOutlivesTheServersJoinBound() {
        XCTAssertGreaterThan(RPCClient.controlTimeoutSeconds, 20)
        XCTAssertGreaterThan(RPCClient.controlTimeoutSeconds, RPCClient.requestTimeoutSeconds)
    }

    // MARK: - --source/--pid/--app-name/--title

    func testSourceOptionsParse() throws {
        let parsed = try Record.parse([
            "start", "--source", "app", "--pid", "4242",
            "--app-name", "MeetingSimulator", "--title", "Weekly Sync",
        ])
        XCTAssertEqual(parsed.source, .app)
        XCTAssertEqual(parsed.pid, 4242)
        XCTAssertEqual(parsed.appName, "MeetingSimulator")
        XCTAssertEqual(parsed.title, "Weekly Sync")
    }

    func testSourceOptionsDefaultToNil() throws {
        let parsed = try Record.parse(["start"])
        XCTAssertNil(parsed.source)
        XCTAssertNil(parsed.pid)
        XCTAssertNil(parsed.appName)
        XCTAssertNil(parsed.title)
    }

    /// The wire body `Record.run()` sends — pinned without a running server.
    /// The key names must match the server's `RecordActionPayload` decoder
    /// exactly, or a well-typed option silently no-ops instead of failing.
    func testPayloadOmitsUnsetOptionalFields() {
        let payload = Record.payload(action: .start, source: nil, pid: nil, appName: nil, title: nil)
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload["action"] as? String, "start")
    }

    func testPayloadCarriesAppSourceFields() {
        let payload = Record.payload(
            action: .start, source: .app, pid: 4242, appName: "MeetingSimulator", title: "Weekly Sync",
        )
        XCTAssertEqual(payload["action"] as? String, "start")
        XCTAssertEqual(payload["source"] as? String, "app")
        XCTAssertEqual(payload["pid"] as? Int32, 4242)
        XCTAssertEqual(payload["appName"] as? String, "MeetingSimulator")
        XCTAssertEqual(payload["title"] as? String, "Weekly Sync")
    }
}
