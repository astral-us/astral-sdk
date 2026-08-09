import XCTest
import PhroverKit
@testable import PhroverCloud

@MainActor
final class HybridBrainTests: XCTestCase {
    func testUsesOnDeviceFirstWhileOnline() async throws {
        let order = CallOrder()
        let onDevice = RecordingBrain(name: "on_device", order: order, result: .success(.init(decision: .done)))
        let cloud = RecordingBrain(name: "cloud", order: order, result: .success(.init(decision: .say("cloud"))))
        let brain = HybridBrain(cloud: cloud, onDevice: onDevice, isOnline: { true })

        let output = try await brain.nextAction(MissionContext(utterance: "go to the chair"))

        XCTAssertEqual(output.decision, .done)
        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertEqual(order.names, ["on_device"])
    }

    func testUsesCloudOnlyAfterOnDeviceUnavailable() async throws {
        let order = CallOrder()
        let onDevice = RecordingBrain(
            name: "on_device",
            order: order,
            result: .failure(RoverBrainError.onDeviceUnavailable(.modelNotReady))
        )
        let cloud = RecordingBrain(name: "cloud", order: order, result: .success(.init(decision: .done)))
        let brain = HybridBrain(cloud: cloud, onDevice: onDevice, isOnline: { true })

        let output = try await brain.nextAction(MissionContext())

        XCTAssertEqual(output.decision, .done)
        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(order.names, ["on_device", "cloud"])
    }

    func testUsesCloudAfterPrimaryStageTimeout() async throws {
        let order = CallOrder()
        let onDevice = RecordingBrain(
            name: "on_device",
            order: order,
            result: .success(.init(decision: .say("late"))),
            delay: .seconds(1)
        )
        let cloud = RecordingBrain(name: "cloud", order: order, result: .success(.init(decision: .done)))
        let brain = HybridBrain(
            cloud: cloud,
            onDevice: onDevice,
            primaryTimeout: .milliseconds(10),
            isOnline: { true }
        )
        let clock = ContinuousClock()
        let start = clock.now

        let output = try await brain.nextAction(MissionContext())

        XCTAssertEqual(output.decision, .done)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        XCTAssertTrue(onDevice.wasCancelled)
        XCTAssertEqual(order.names, ["on_device", "cloud"])
    }

    func testRethrowsWhenOnDeviceAndCloudBothFail() async {
        let order = CallOrder()
        let onDevice = RecordingBrain(name: "on_device", order: order, result: .failure(TestError.onDeviceFailed))
        let cloud = RecordingBrain(name: "cloud", order: order, result: .failure(TestError.cloudFailed))
        let brain = HybridBrain(cloud: cloud, onDevice: onDevice, isOnline: { true })

        do {
            _ = try await brain.nextAction(MissionContext())
            XCTFail("Expected the cloud failure to be rethrown")
        } catch {
            XCTAssertEqual(error as? TestError, .cloudFailed)
        }

        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(cloud.callCount, 1)
        XCTAssertEqual(order.names, ["on_device", "cloud"])
    }

    func testDoesNotCallCloudWhileOffline() async {
        let order = CallOrder()
        let onDevice = RecordingBrain(name: "on_device", order: order, result: .failure(TestError.onDeviceFailed))
        let cloud = RecordingBrain(name: "cloud", order: order, result: .success(.init(decision: .done)))
        let brain = HybridBrain(cloud: cloud, onDevice: onDevice, isOnline: { false })

        do {
            _ = try await brain.nextAction(MissionContext())
            XCTFail("Expected the on-device failure to be rethrown")
        } catch {
            XCTAssertEqual(error as? TestError, .onDeviceFailed)
        }

        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(cloud.callCount, 0)
        XCTAssertEqual(order.names, ["on_device"])
    }

    func testUnavailableOnDeviceWithoutConfiguredCloudRethrowsForMissionFallback() async {
        let order = CallOrder()
        let onDevice = RecordingBrain(
            name: "on_device",
            order: order,
            result: .failure(RoverBrainError.onDeviceUnavailable(.modelNotReady))
        )
        let brain = HybridBrain(cloud: nil, onDevice: onDevice, isOnline: { true })
        let logBefore = runtimeLog()

        do {
            _ = try await brain.nextAction(MissionContext())
            XCTFail("Expected the typed on-device failure to be rethrown")
        } catch {
            XCTAssertEqual(error as? RoverBrainError, .onDeviceUnavailable(.modelNotReady))
        }

        let selectionLog = String(runtimeLog().dropFirst(logBefore.count))
        XCTAssertEqual(onDevice.callCount, 1)
        XCTAssertEqual(order.names, ["on_device"])
        XCTAssertTrue(selectionLog.contains("mission_brain_selected brain=on_device"))
        XCTAssertTrue(selectionLog.contains("reason=on_device_failed"))
        XCTAssertFalse(selectionLog.contains("brain=cloud"))
    }

    private func runtimeLog() -> String {
        guard let url = RuntimeFileLog.logFileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

@MainActor
private final class RecordingBrain: RoverBrain {
    private let name: String
    private let order: CallOrder
    private let result: Result<BrainOutput, Error>
    private let delay: Duration?
    private(set) var callCount = 0
    private(set) var wasCancelled = false

    init(name: String, order: CallOrder, result: Result<BrainOutput, Error>, delay: Duration? = nil) {
        self.name = name
        self.order = order
        self.result = result
        self.delay = delay
    }

    func nextAction(_ context: MissionContext) async throws -> BrainOutput {
        callCount += 1
        order.names.append(name)
        defer { wasCancelled = Task.isCancelled }
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }
}

@MainActor
private final class CallOrder {
    var names: [String] = []
}

private enum TestError: Error, Equatable {
    case onDeviceFailed
    case cloudFailed
}
