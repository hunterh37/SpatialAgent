import AgentProtocol
import XCTest
@testable import HomeBridge

final class ToolSafetyTests: XCTestCase {
    /// The client enforces safety independently of what the server asserts; a compromised
    /// or hallucinating server cannot unlock a door (spec/04-home.md).
    func testServerCannotDowngradeAnUnsafeTool() {
        XCTAssertEqual(ToolSafety.effective(name: "set_lock", serverAsserted: .safe), .unsafe)
    }

    func testClientCannotDowngradeAServerUnsafeAssertion() {
        XCTAssertEqual(ToolSafety.effective(name: "set_light", serverAsserted: .unsafe), .unsafe)
    }

    /// Unknown tools fail closed, matching `ToolRegistry.safety_of` on the server.
    func testUnknownToolIsUnsafe() {
        XCTAssertEqual(ToolSafety.local("detonate"), .unsafe)
    }

    func testSafeToolStaysSafeWhenBothAgree() {
        XCTAssertEqual(ToolSafety.effective(name: "set_light", serverAsserted: .safe), .safe)
    }
}

@MainActor
final class ConfirmationGateTests: XCTestCase {
    func testConfirmResolvesConfirmed() async {
        let gate = ConfirmationGate()
        let task = Task {
            await gate.request(
                callId: "c1", toolName: "set_lock", deviceName: "Front Door",
                summary: "Unlock the Front Door"
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gate.pending.count, 1)
        gate.confirm("c1")
        let outcome = await task.value
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertTrue(gate.pending.isEmpty)
    }

    func testCancelIsTheDefaultOutcomeShape() async {
        let gate = ConfirmationGate()
        let task = Task {
            await gate.request(
                callId: "c2", toolName: "set_lock", deviceName: "Front Door", summary: "Unlock"
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.cancel("c2")
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testSummaryIsPlainLanguageNotAFunctionCall() {
        let summary = ConfirmationGate.summarize(
            tool: "set_lock",
            args: ["device_id": .string("lock.front"), "locked": .bool(false)],
            device: Device(id: "lock.front", name: "Front Door", kind: .lock)
        )
        XCTAssertEqual(summary, "Unlock the Front Door")
    }
}

@MainActor
final class MockHomeProviderTests: XCTestCase {
    func testSetLightMutatesState() async throws {
        let home = MockHomeProvider()
        let state = try await home.execute(
            tool: "set_light",
            args: ["device_id": .string("light.desk"), "on": .bool(true)]
        )
        XCTAssertEqual(state["on"]?.boolValue, true)
        XCTAssertEqual(
            home.devices.first { $0.id == "light.desk" }?.state?["on"]?.boolValue, true
        )
    }

    func testUnknownDeviceNamesTheDeviceInTheSpokenFailure() async {
        let home = MockHomeProvider()
        do {
            _ = try await home.execute(
                tool: "get_device_state", args: ["device_id": .string("light.attic")]
            )
            XCTFail("expected throw")
        } catch let error as HomeError {
            XCTAssertEqual(error, .unknownDevice("light.attic"))
            XCTAssertTrue(error.spokenLine.contains("light.attic"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
}
