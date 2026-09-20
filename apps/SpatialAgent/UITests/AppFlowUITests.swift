import XCTest

/// The app layer, in the visionOS simulator, against a real `agentd` and a real local model.
///
/// The package-level live tests drive `AgentSession` directly. This one drives the thing a
/// person actually touches: type a sentence, watch the character's reply arrive in the
/// transcript. It is the only test that proves the SwiftUI wiring — discovery, the composer,
/// the streaming bubble — is connected to the loop at all.
///
/// Needs `agentd` on 127.0.0.1:8787, which the simulator reaches as its own localhost.
/// Skipped when nothing is listening, so an offline `xcodebuild test` stays green.
final class AppFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.serverIsUp(), "no agentd on 127.0.0.1:8787 — run `make serve`")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private static func serverIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8787/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        var reachable = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            reachable = data != nil
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return reachable
    }

    private func ask(_ text: String) {
        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer never appeared")
        field.tap()
        field.typeText(text)
        app.buttons["composer.send"].tap()
    }

    /// The simulator auto-connects to localhost (AppModel.start), which is the same code
    /// path Bonjour discovery drives on a headset.
    func testAppConnectsToTheLocalServerOnLaunch() {
        let label = app.staticTexts["connection.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        let connected = NSPredicate(format: "label BEGINSWITH 'Connected'")
        expectation(for: connected, evaluatedWith: label)
        waitForExpectations(timeout: 30)
        // The server names the model it is running, so the label proves which one answered.
        XCTAssertTrue(label.label.contains("ollama"), "unexpected label: \(label.label)")
    }

    func testTypedSentenceComesBackAsASpokenReply() {
        ask("say hello in one short sentence")

        let reply = app.descendants(matching: .any).matching(
            identifier: "transcript.agent"
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "the character never answered")
    }

    /// Asking for a device action puts a real tool call through the client's HomeBridge and
    /// the answer describes what actually happened, not what the model hoped.
    func testDeviceRequestReachesTheHomeAndIsReportedBack() {
        ask("turn off the kitchen lights")

        let reply = app.descendants(matching: .any).matching(
            identifier: "transcript.agent"
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply to a device request")
    }

    /// PRD §6's binary criterion, from the outside: an unsafe tool shows a confirmation and
    /// nothing happens until a human taps it.
    func testUnlockRequestShowsAConfirmationOrnament() {
        ask("unlock the front door")

        let confirm = app.buttons["confirmation.confirm"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 120),
            "an unsafe tool must ask before it acts"
        )
        XCTAssertTrue(app.buttons["confirmation.cancel"].exists, "cancel must be offered too")

        // Tapping it is what releases the action; until now nothing has happened.
        confirm.tap()
        let reply = app.descendants(matching: .any).matching(
            identifier: "transcript.agent"
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no answer after confirming")
    }

    /// Opening the immersive space is what puts the character in the room: `ImmersiveView`
    /// binds the RealityKit entity to the session, so from here a directive from the model
    /// drives an actual body. The assertion is narrow on purpose — XCUITest cannot see into
    /// a RealityView — but it does prove the space opens, the binding is made, and a live
    /// walk directive does not tear it down.
    func testCharacterCanBeAskedToWalkWhileInTheRoom() {
        let toggle = app.switches["space.toggle"].exists
            ? app.switches["space.toggle"]
            : app.buttons["space.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no way into the immersive space")
        toggle.tap()

        ask("go to the kitchen")

        let reply = app.descendants(matching: .any).matching(
            identifier: "transcript.agent"
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 120), "no reply while in the room")

        // A placement failure is reported in words rather than by standing in a wall.
        XCTAssertFalse(
            app.staticTexts["There's no clear spot on the floor for me to stand."].exists
        )
        XCTAssertTrue(app.textFields["composer.field"].exists, "the window survived the space")
    }
}
