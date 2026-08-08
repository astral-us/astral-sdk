import XCTest
import RoverNav
import CoreVideo
import simd
@testable import PhroverKit

@MainActor
final class NavigationSafetyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestURLProtocol.reset()
    }

    func testGoalAssessmentDoesNotDriveOrMutateNavigationState() throws {
        let (navigation, ar) = makeNavigation()
        ar.resetTracking(generation: 1, runSession: false)
        XCTAssertTrue(ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: 1,
            trackingQuality: .normal,
            sessionGeneration: 1
        )))

        let assessment = navigation.assessGoal(Vec2(1, 0))

        XCTAssertTrue(assessment.isReachable)
        XCTAssertGreaterThan(assessment.pathDistance, 0)
        XCTAssertEqual(navigation.state, .idle)
        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertEqual(TestURLProtocol.requestCount, 0)
    }

    func testGoalAssessmentReportsGoalOutsideCurrentCostmapAsUnreachable() {
        let (navigation, ar) = makeNavigation()
        ar.resetTracking(generation: 1, runSession: false)
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: 1,
            trackingQuality: .normal,
            sessionGeneration: 1
        ))

        let assessment = navigation.assessGoal(Vec2(20, 0))

        XCTAssertFalse(assessment.isReachable)
        XCTAssertEqual(assessment.pathDistance, .infinity)
        XCTAssertEqual(navigation.state, .idle)
    }

    func testStopAndWaitReturnsOnlyAfterTransportStopCompletes() async {
        let (navigation, _) = makeNavigation()
        TestURLProtocol.delay = 0.08
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await navigation.stopAndWait()
        }

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(70))
        XCTAssertEqual(TestURLProtocol.requestCount, 1)
        XCTAssertEqual(navigation.state, .idle)
    }

    func testLimitedTrackingStopsAndFailsWithinConfiguredBound() async {
        let (navigation, ar) = makeNavigation(trackingRecoveryTimeout: 0.05)
        ar.resetTracking(generation: 1, runSession: false)
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            trackingQuality: .limited,
            sessionGeneration: 1
        ))
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            navigation.navigate(to: Vec2(1, 0))
            while navigation.state == .driving {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        XCTAssertLessThan(elapsed, .milliseconds(300))
        XCTAssertEqual(navigation.state, .failed("AR tracking did not recover in time."))
        XCTAssertGreaterThanOrEqual(TestURLProtocol.requestCount, 1)
    }

    func testStaleAndLimitedObservationsAreNotUsableForNavigation() {
        let now = ProcessInfo.processInfo.systemUptime
        let pose = Pose2D(position: .zero, yaw: 0)

        XCTAssertFalse(NavigationController.isNavigationObservationUsable(PoseObservation(
            pose: pose,
            frameSequence: 1,
            timestamp: now,
            trackingQuality: .limited,
            sessionGeneration: 1
        ), uptime: now))
        XCTAssertFalse(NavigationController.isNavigationObservationUsable(PoseObservation(
            pose: pose,
            frameSequence: 2,
            timestamp: now - RoverConfig.navigationTrackingFreshness - 0.01,
            trackingQuality: .normal,
            sessionGeneration: 1
        ), uptime: now))
    }

    func testUncorrelatedObstacleNearTargetDoesNotCountAsArrival() {
        let state = NavigationController.stateAfterObstacleStop(
            pose: Pose2D(position: Vec2(0.4, 0), yaw: 0),
            goal: Vec2(0.9, 0),
            clearance: 0.32
        )

        XCTAssertEqual(state, .failed("Obstacle ahead at 0.32 m."))
    }

    func testObstacleBeforeTargetStopsAsFailed() {
        let state = NavigationController.stateAfterObstacleStop(
            pose: Pose2D(position: .zero, yaw: 0),
            goal: Vec2(2.0, 0),
            clearance: 0.28
        )

        XCTAssertEqual(state, .failed("Obstacle ahead at 0.28 m."))
    }

    func testVisualTargetApproachStopsAtThirtyCentimeters() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.29,
                stopDistance: 0.30
            ),
            .arrived
        )
    }

    func testVisualTargetApproachBrakesBeforeStandOffToCompensateForOvershoot() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.39,
                stopDistance: 0.30
            ),
            .arrived
        )
    }

    func testVisualTargetApproachRelaxesObstacleGuardOnlyNearProjectedGoal() {
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 0.99,
                forwardClearance: 0.41,
                stopDistance: 0.30
            ),
            .approach
        )
        XCTAssertEqual(
            NavigationController.visualTargetApproachDecision(
                distanceToGoal: 1.21,
                forwardClearance: 0.29,
                stopDistance: 0.30
            ),
            .inactive
        )
    }

    func testVisualTargetApproachSlowsForwardCommandBeforeStopDistance() {
        let command = NavigationController.visualTargetApproachCommand(
            WheelCommand(left: 0.35, right: 0.31),
            forwardClearance: 0.45,
            stopDistance: 0.30
        )

        XCTAssertEqual(command.left, RoverConfig.visualTargetApproachMaxWheelSpeed, accuracy: 0.001)
        XCTAssertEqual(command.right, 0.106, accuracy: 0.001)
    }

    func testVisualTargetApproachKeepsCommandOutsideSlowdownDistance() {
        let original = WheelCommand(left: 0.35, right: 0.31)

        let command = NavigationController.visualTargetApproachCommand(
            original,
            forwardClearance: 0.61,
            stopDistance: 0.30
        )

        XCTAssertEqual(command, original)
    }

    func testCommandFailureStopsNavigationAsFailed() {
        let state = NavigationController.stateAfterCommandFailure(FakeCommandError.timedOut)

        XCTAssertEqual(state, .failed("Rover command failed: Timed out talking to rover."))
    }


    func testDepthSafetyUnavailableRejectsTranslationalCommand() {
        let guardLayer = ObstacleGuard()
        let command = WheelCommand(left: 0.30, right: 0.25)
        let observation = DepthSafetyObservation.unavailable(
            .missingRawDepth,
            sampleAge: 0,
            motionClass: .forward
        )

        XCTAssertEqual(
            guardLayer.evaluate(command: command, depthSafety: observation),
            .stopDepth(observation)
        )
    }

    func testDepthSafetyCautionCapsCommandWithoutChangingCurvature() {
        let guardLayer = ObstacleGuard()
        let observation = DepthSafetyObservation(
            state: .caution,
            clearance: 0.60,
            supportCount: 5,
            sampleAge: 0.03,
            requiredStoppingDistance: 0.42,
            motionClass: .curved,
            speedLimit: 0.12
        )

        let decision = guardLayer.evaluate(
            command: WheelCommand(left: 0.30, right: 0.15),
            depthSafety: observation
        )

        XCTAssertEqual(
            decision,
            .allow(WheelCommand(left: 0.12, right: 0.06), depthSafety: observation)
        )
    }

    func testStaleAckIsIgnoredUntilNavigationSendsFirstCommand() {
        let guardLayer = ObstacleGuard(watchdogTimeout: 0.5)
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 10),
            feedback: nil,
            requireFreshAck: false
        )

        XCTAssertEqual(decision, .go)
    }

    func testStaleAckStopsActiveNavigationAfterFirstCommand() {
        let guardLayer = ObstacleGuard(watchdogTimeout: 0.5)
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 10),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .stopCommsLost)
    }

    func testDefaultWatchdogToleratesShortCommandLoopGap() {
        let guardLayer = ObstacleGuard()
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 11.2),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .go)
    }

    func testDefaultWatchdogStopsLongCommandLoopGap() {
        let guardLayer = ObstacleGuard()
        let decision = guardLayer.evaluate(
            forwardClearance: 2.0,
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 12.1),
            feedback: nil,
            requireFreshAck: true
        )

        XCTAssertEqual(decision, .stopCommsLost)
    }

    func testAckAgeFieldFormatsCurrentAckAge() {
        let value = NavigationController.ackAgeField(
            lastAckAt: Date(timeIntervalSince1970: 10.0),
            now: Date(timeIntervalSince1970: 11.234)
        )

        XCTAssertEqual(value, "1.23")
    }

    func testAckAgeFieldReportsMissingAck() {
        let value = NavigationController.ackAgeField(lastAckAt: nil)

        XCTAssertEqual(value, "none")
    }

    func testForwardObstacleCanBeIgnoredForInPlaceRotation() {
        let guardLayer = ObstacleGuard(stopDistance: 0.45)
        let decision = guardLayer.evaluate(
            forwardClearance: 0.30,
            lastAckAt: nil,
            feedback: nil,
            checkForwardObstacle: false
        )

        XCTAssertEqual(decision, .go)
    }

    func testNavigationTelemetryFieldsIncludeGoalPoseDistanceAndWheelCommand() {
        let fields = NavigationController.driveTelemetryFields(
            pose: Pose2D(position: Vec2(1.0, 2.0), yaw: .pi / 2),
            goal: Vec2(1.0, 3.0),
            command: WheelCommand(left: 0.12, right: 0.34),
            consecutiveCommandFailures: 1
        )

        XCTAssertEqual(fields["goal_x"], "1.00")
        XCTAssertEqual(fields["goal_y"], "3.00")
        XCTAssertEqual(fields["pose_x"], "1.00")
        XCTAssertEqual(fields["pose_y"], "2.00")
        XCTAssertEqual(fields["pose_yaw_deg"], "90")
        XCTAssertEqual(fields["distance_to_goal"], "1.00")
        XCTAssertEqual(fields["wheel_left"], "0.12")
        XCTAssertEqual(fields["wheel_right"], "0.34")
        XCTAssertEqual(fields["command_failures"], "1")
    }

    func testReachedGoalWithMissingDepthDoesNotReportArrival() async {
        let (navigation, ar) = makeNavigation()
        ar.resetTracking(generation: 1, runSession: false)
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            trackingQuality: .normal,
            sessionGeneration: 1
        ))

        navigation.navigate(to: Vec2(0.10, 0))
        while navigation.state == .driving {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            navigation.state,
            .failed("Depth safety stop at arrival: missing_raw_depth.")
        )
    }

    func testRotationWithoutRawDepthStopsBeforeSendingMotorCommand() async {
        let (navigation, ar) = makeNavigation()
        ar.resetTracking(generation: 1, runSession: false)
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            trackingQuality: .normal,
            sessionGeneration: 1
        ))

        await navigation.rotate(by: .pi / 2)

        XCTAssertEqual(
            navigation.state,
            .failed("Depth safety stop while rotating: missing_raw_depth.")
        )
        XCTAssertEqual(TestURLProtocol.requestCount, 2)
    }

    func testBlindRotationWaitsForNewDepthThenTimesOutFailClosed() async {
        let (navigation, ar) = makeNavigation(depthRecoveryTimeout: 0.03)
        ar.resetTracking(generation: 1, runSession: false)
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: 0),
            frameSequence: 1,
            timestamp: ProcessInfo.processInfo.systemUptime,
            trackingQuality: .normal,
            sessionGeneration: 1
        ))
        ingestBlindDepth(into: ar)
        let versionBefore = ar.depthSnapshotVersion

        await navigation.rotate(by: .pi / 2)

        XCTAssertEqual(ar.depthSnapshotVersion, versionBefore)
        XCTAssertEqual(
            navigation.state,
            .failed("I can’t safely see the space needed to turn. Reposition the rover or camera and try again.")
        )
        XCTAssertEqual(TestURLProtocol.requestCount, 3,
                       "initial stop, blind-depth stop, and final stop; never a movement command")
    }

    func testFreshDepthRetryAuthorizesOriginalRotation() async {
        var depthState: DepthSafetyState = .unavailable(.blindSweptVolume)
        let (navigation, ar) = makeNavigation(
            depthRecoveryTimeout: 0.5,
            depthSafetyState: { _ in depthState }
        )
        ingestTrackedPose(into: ar, yaw: 0, sequence: 1)
        ingestBlindDepth(into: ar)
        let initialVersion = ar.depthSnapshotVersion

        let rotation = Task { await navigation.rotate(by: .pi / 2) }
        await waitForRequestCount(2)
        try? await Task.sleep(for: .milliseconds(20))
        depthState = .clear
        ingestBlindDepth(into: ar)
        await waitForNavigationCommandCount(1)
        ingestTrackedPose(into: ar, yaw: .pi / 2, sequence: 2)
        await rotation.value

        XCTAssertGreaterThan(ar.depthSnapshotVersion, initialVersion)
        XCTAssertEqual(navigation.state, .arrived)
        XCTAssertEqual(navigationCommandCount, 1)
    }

    func testPostWaitCommsVetoPreventsRecoveredMotion() async {
        var depthState: DepthSafetyState = .unavailable(.blindSweptVolume)
        let (navigation, ar) = makeNavigation(
            depthRecoveryTimeout: 0.5,
            obstacleGuard: ObstacleGuard(watchdogTimeout: 0),
            depthSafetyState: { _ in depthState }
        )
        ingestTrackedPose(into: ar, yaw: 0, sequence: 1)
        ingestBlindDepth(into: ar)

        let rotation = Task { await navigation.rotate(by: .pi / 2) }
        await waitForRequestCount(2)
        try? await Task.sleep(for: .milliseconds(20))
        depthState = .clear
        ingestBlindDepth(into: ar)
        await rotation.value

        XCTAssertEqual(navigation.state, .failed("Rover command link lost."))
        XCTAssertEqual(navigationCommandCount, 0)
    }

    func testPostWaitTippingVetoPreventsRecoveredMotion() async {
        var depthState: DepthSafetyState = .unavailable(.blindSweptVolume)
        var feedback: RoverFeedback?
        let (navigation, ar) = makeNavigation(
            depthRecoveryTimeout: 0.5,
            safetyFeedback: { feedback },
            depthSafetyState: { _ in depthState }
        )
        ingestTrackedPose(into: ar, yaw: 0, sequence: 1)
        ingestBlindDepth(into: ar)

        let rotation = Task { await navigation.rotate(by: .pi / 2) }
        await waitForRequestCount(2)
        try? await Task.sleep(for: .milliseconds(20))
        feedback = RoverFeedback.parse("{\"r\":0.7}")
        depthState = .clear
        ingestBlindDepth(into: ar)
        await rotation.value

        XCTAssertEqual(navigation.state, .failed("Rover may be tipping."))
        XCTAssertEqual(navigationCommandCount, 0)
    }

    func testFreshBlindDepthRejectsExactArcAndSendsNoMotion() async {
        var observedMotionClasses: [DepthSafetyMotionClass] = []
        let (navigation, ar) = makeNavigation(
            depthRecoveryTimeout: 0.5,
            depthSafetyState: { command in
                observedMotionClasses.append(DepthSafetyMotionClass.classify(command))
                return .unavailable(.blindSweptVolume)
            }
        )
        ingestTrackedPose(into: ar, yaw: 0, sequence: 1)
        ingestBlindDepth(into: ar)

        let rotation = Task { await navigation.rotate(by: .pi / 2) }
        await waitForRequestCount(2)
        try? await Task.sleep(for: .milliseconds(20))
        ingestBlindDepth(into: ar)
        await rotation.value

        XCTAssertEqual(observedMotionClasses, [.rotating, .rotating, .curved])
        XCTAssertEqual(
            navigation.state,
            .failed("I can’t safely see the space needed to turn. Reposition the rover or camera and try again.")
        )
        XCTAssertEqual(navigationCommandCount, 0)
    }

    func testPathFollowingBlindInitialTurnUsesDepthVisibleArc() async {
        var observedMotionClasses: [DepthSafetyMotionClass] = []
        let (navigation, ar) = makeNavigation(
            depthRecoveryTimeout: 0.5,
            depthSafetyState: { command in
                let motionClass = DepthSafetyMotionClass.classify(command)
                observedMotionClasses.append(motionClass)
                return motionClass == .curved ? .clear : .unavailable(.blindSweptVolume)
            }
        )
        ingestTrackedPose(into: ar, yaw: 0, sequence: 1)
        ingestBlindDepth(into: ar)

        navigation.navigate(to: Vec2(0, 1))
        await waitForMotionClass(.rotating, in: { observedMotionClasses })
        await waitForRequestCount(2)
        try? await Task.sleep(for: .milliseconds(20))
        ingestBlindDepth(into: ar)
        await waitForNavigationCommandCount(1)
        await navigation.stopAndWait()

        XCTAssertTrue(observedMotionClasses.contains(.curved))
        XCTAssertGreaterThanOrEqual(navigationCommandCount, 1)
    }

    private func makeNavigation(
        trackingRecoveryTimeout: TimeInterval = RoverConfig.navigationTrackingRecoveryTimeout,
        depthRecoveryTimeout: TimeInterval = RoverConfig.scanDepthRecoveryTimeout,
        obstacleGuard: ObstacleGuard = ObstacleGuard(),
        safetyFeedback: @escaping () -> RoverFeedback? = { nil },
        depthSafetyState: ((WheelCommand) -> DepthSafetyState)? = nil
    ) -> (NavigationController, ARSessionManager) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let ar = ARSessionManager()
        let control = RoverControl(host: "rover.test", session: URLSession(configuration: configuration))
        if let depthSafetyState {
            return (NavigationController(
                ar: ar,
                control: control,
                trackingRecoveryTimeout: trackingRecoveryTimeout,
                scanDepthRecoveryTimeout: depthRecoveryTimeout,
                guardLayer: obstacleGuard,
                safetyFeedback: safetyFeedback,
                depthSafetyObservation: { command in
                    DepthSafetyObservation(
                        state: depthSafetyState(command),
                        clearance: .infinity,
                        supportCount: 0,
                        sampleAge: 0,
                        requiredStoppingDistance: 0.3,
                        motionClass: DepthSafetyMotionClass.classify(command),
                        speedLimit: nil
                    )
                }
            ), ar)
        }
        return (NavigationController(
            ar: ar,
            control: control,
            trackingRecoveryTimeout: trackingRecoveryTimeout,
            scanDepthRecoveryTimeout: depthRecoveryTimeout
        ), ar)
    }

    private func ingestTrackedPose(into ar: ARSessionManager, yaw: Double, sequence: UInt64) {
        if sequence == 1 {
            ar.resetTracking(generation: 1, runSession: false)
        }
        _ = ar.ingest(PoseObservation(
            pose: Pose2D(position: .zero, yaw: yaw),
            frameSequence: sequence,
            timestamp: ProcessInfo.processInfo.systemUptime,
            trackingQuality: .normal,
            sessionGeneration: 1
        ))
    }

    private func ingestBlindDepth(into ar: ARSessionManager) {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            80,
            60,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &pixelBuffer
        )
        let map = pixelBuffer!
        CVPixelBufferLockBaseAddress(map, [])
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let base = CVPixelBufferGetBaseAddress(map)!.assumingMemoryBound(to: Float32.self)
        for row in 0..<60 {
            for column in 0..<80 { base[row * stride + column] = 3 }
        }
        CVPixelBufferUnlockBaseAddress(map, [])
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(20, 0, 0),
            SIMD3<Float>(0, 8, 0),
            SIMD3<Float>(40, 30, 1)
        ))
        var transform = matrix_identity_float4x4
        transform.columns.3.y = 0.55
        ar.ingestDepthSafety(
            rawDepthMap: map,
            intrinsics: intrinsics,
            cameraTransform: transform,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    private var navigationCommandCount: Int {
        TestURLProtocol.requestURLs.filter { url in
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "json" })?.value,
                  let data = value.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return payload["T"] as? Int == RoverConfig.Opcode.speedControl
        }.count
    }

    private func waitForRequestCount(_ expected: Int) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while TestURLProtocol.requestCount < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(TestURLProtocol.requestCount, expected)
    }

    private func waitForNavigationCommandCount(_ expected: Int) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while navigationCommandCount < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(navigationCommandCount, expected)
    }

    private func waitForMotionClass(
        _ expected: DepthSafetyMotionClass,
        in values: () -> [DepthSafetyMotionClass]
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !values().contains(expected), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(values().contains(expected))
    }

}

private enum FakeCommandError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "Timed out talking to rover."
    }
}
