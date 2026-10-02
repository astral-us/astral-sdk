import XCTest
@testable import PhroverOperator
import PhroverKit

@MainActor
final class ConversationViewModelTests: XCTestCase {
    func testStationaryAcquisitionPhasesExplainBehaviorAndKeepStopAvailable() async {
        for (state, label) in [(FollowMeState.pausing, "Pausing — five seconds"),
                               (.aligning, "Aligning toward you…"),
                               (.waitingForMovement, "Ready — walk away to begin following")] {
            var stops = 0
            let model = ConversationViewModel(stop: { stops += 1; return .accepted }, followState: { state })
            XCTAssertEqual(model.status, label)
            XCTAssertTrue(model.showsStopFollowing)
            await model.stopFollowing()
            XCTAssertEqual(stops, 1)
        }
    }

    func testFinalSpeechRoutesFollowMeWithoutTextEntry() async {
        var received: [String] = []
        let model = ConversationViewModel(submit: { text in
            received.append(text)
            return .accepted
        }, stop: { .accepted }, followState: { .idle })

        await model.submitFinalSpeech("follow me")

        XCTAssertEqual(received, ["follow me"])
        XCTAssertNil(model.errorMessage)
    }

    func testRejectedFinalSpeechDisplaysGuidanceWhileStopRemainsAvailable() async {
        let model = ConversationViewModel(submit: { _ in .rejected("Stop following first.") },
                                          stop: { .accepted }, followState: { .searching })
        await model.submitFinalSpeech("go to the kitchen")
        XCTAssertEqual(model.errorMessage, "Stop following first.")
        XCTAssertTrue(model.showsStopFollowing)
    }

    func testLeavingTalkInhibitsFollowBeforeWaitingForStop() async {
        var events: [String] = []
        let model = ConversationViewModel(submit: { _ in .accepted },
                                          stop: { events.append("confirmed stop"); return .accepted },
                                          followState: { .following },
                                          inhibit: { events.append("inhibited") })
        let stopped = await model.leaveTalk()
        XCTAssertTrue(stopped)
        XCTAssertEqual(events, ["inhibited", "confirmed stop"])
    }

    func testLeavingTalkStopsAnOrdinaryMissionEvenWithoutActiveFollow() async {
        var stopped = false
        let model = ConversationViewModel(submit: { _ in .accepted },
                                          stop: { stopped = true; return .accepted },
                                          followState: { .idle })
        let confirmed = await model.leaveTalk()
        XCTAssertTrue(confirmed)
        XCTAssertTrue(stopped)
    }

    func testFollowStartPermissionRejectsOtherTabMotion() {
        XCTAssertTrue(RootView.followMayStart(navigationState: .idle, silentSearchPhase: .setup))
        XCTAssertFalse(RootView.followMayStart(navigationState: .driving, silentSearchPhase: .setup))
        XCTAssertFalse(RootView.followMayStart(navigationState: .idle, silentSearchPhase: .searching))
    }

    func testStopButtonStaysVisibleWhenMotorStopWasNotConfirmed() {
        let model = ConversationViewModel(followState: {
            .failed("Rover stop could not be confirmed.")
        })
        XCTAssertTrue(model.showsStopFollowing)
    }
}
