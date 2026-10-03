import Foundation
import RoverNav

enum FollowMotionPurpose: String, Sendable { case followScan, followAlignment, followReady, followGoal }
enum FollowMotionStopOutcome: String, Sendable { case unknown, pending, confirmed, failed }
enum FollowMotionDeliverySource: String, Sendable { case stream, result, confirmation }
enum FollowMotionStopOrigin: String, Sendable { case pulse, independent, final, detection, cleanup }

struct FollowMotionRequestContext: Sendable, Equatable {
    let sessionGeneration: UInt64
    let requestToken: UInt64
    let purpose: FollowMotionPurpose
    let phase: String
    let scanUsed: Double?
    let scanRemaining: Double?
    init(sessionGeneration: UInt64, requestToken: UInt64, purpose: FollowMotionPurpose, phase: String,
         scanUsed: Double? = nil, scanRemaining: Double? = nil) {
        self.sessionGeneration = sessionGeneration
        self.requestToken = requestToken
        self.purpose = purpose
        self.phase = phase
        self.scanUsed = scanUsed
        self.scanRemaining = scanRemaining
    }
}

enum FollowMotionRequest: Sendable {
    case scan(Double), alignment(Double), ready, following(Vec2, Double)
    var purpose: FollowMotionPurpose {
        switch self { case .scan: .followScan; case .alignment: .followAlignment; case .ready: .followReady; case .following: .followGoal }
    }
    var requestedRotation: Double? {
        switch self { case .scan(let angle), .alignment(let angle): angle; default: nil }
    }
}

struct FollowMotionOperationContext: Sendable, Equatable {
    let request: FollowMotionRequestContext?
    let controllerOperationID: UInt64?
    let purpose: FollowMotionPurpose?
    let profile: FollowScanRotationProfile?
    let requestedRotation: Double?
    let targetYaw: Double?
    init(request: FollowMotionRequestContext?, controllerOperationID: UInt64?, purpose: FollowMotionPurpose?,
         profile: FollowScanRotationProfile?, requestedRotation: Double? = nil, targetYaw: Double? = nil) {
        self.request = request
        self.controllerOperationID = controllerOperationID
        self.purpose = purpose
        self.profile = profile
        self.requestedRotation = requestedRotation
        self.targetYaw = targetYaw
    }
    static let unknown = Self(request: nil, controllerOperationID: nil, purpose: nil, profile: nil)
}

struct FollowMotionFailureDelivery: Sendable {
    let context: FollowMotionOperationContext
    let reason: NavigationFailure
    let stopOutcome: FollowMotionStopOutcome
    let source: FollowMotionDeliverySource
    let stale: Bool
    let commandReceipt: RoverCommandDiagnosticReceipt?
    let stopReceipt: RoverCommandDiagnosticReceipt?
    init(context: FollowMotionOperationContext, reason: NavigationFailure, stopOutcome: FollowMotionStopOutcome,
         source: FollowMotionDeliverySource, stale: Bool = false,
         commandReceipt: RoverCommandDiagnosticReceipt? = nil, stopReceipt: RoverCommandDiagnosticReceipt? = nil) {
        self.context = context
        self.reason = reason
        self.stopOutcome = stopOutcome
        self.source = source
        self.stale = stale
        self.commandReceipt = commandReceipt
        self.stopReceipt = stopReceipt
    }
}

struct FollowMotionResult: Sendable {
    var outcome: FollowMotionOutcome {
        if let deferred, failure == nil, stopOutcome != .failed { return .notStarted(deferred) }
        return .navigation(result)
    }
    /// Explicit not-started outcome; the legacy NavigationResult remains compatible.
    let deferred: FollowReadyDeferral?
    let result: NavigationResult
    let context: FollowMotionOperationContext
    let failure: FollowMotionFailureDelivery?
    let stopOutcome: FollowMotionStopOutcome
    let commandReceipt: RoverCommandDiagnosticReceipt?
    let stopReceipt: RoverCommandDiagnosticReceipt?
    init(result: NavigationResult, context: FollowMotionOperationContext, failure: FollowMotionFailureDelivery?,
         stopOutcome: FollowMotionStopOutcome = .unknown, commandReceipt: RoverCommandDiagnosticReceipt? = nil,
         stopReceipt: RoverCommandDiagnosticReceipt? = nil, deferred: FollowReadyDeferral? = nil) {
        self.deferred = deferred
        self.result = result
        self.context = context
        self.failure = failure
        self.stopOutcome = stopOutcome
        self.commandReceipt = commandReceipt
        self.stopReceipt = stopReceipt
    }
}

/// Per-operation evidence, never a mutable lookup of whichever operation is current.
/// Facts are captured synchronously by NavigationController and frozen for delivery.
@MainActor
final class FollowMotionOperationEvidence {
    let initialContext: FollowMotionOperationContext
    var targetYaw: Double?
    var fenced = false
    var emittedFailure = false
    var scanTrace: FollowScanDiagnosticTrace?
    var ownedGeneration: UInt?
    var callerCancellationStop: Task<Bool?, Never>?
    private(set) var primaryFailure: NavigationFailure?
    private(set) var stopOutcome: FollowMotionStopOutcome = .unknown
    private(set) var commandReceipt: RoverCommandDiagnosticReceipt?
    private(set) var stopReceipt: RoverCommandDiagnosticReceipt?

    init(context: FollowMotionOperationContext) { initialContext = context }
    var context: FollowMotionOperationContext {
        .init(request: initialContext.request, controllerOperationID: initialContext.controllerOperationID,
            purpose: initialContext.purpose, profile: initialContext.profile,
            requestedRotation: initialContext.requestedRotation, targetYaw: targetYaw)
    }
    func recordFailure(_ reason: NavigationFailure) {
        if primaryFailure == nil || primaryFailure == .commandFailed { primaryFailure = reason }
    }
    func recordStop(_ outcome: FollowMotionStopOutcome) {
        // A stale success cannot erase an independently observed confirmation failure.
        if stopOutcome != .failed { stopOutcome = outcome }
    }
    func recordCommandReceipt(_ receipt: RoverCommandDiagnosticReceipt) { commandReceipt = receipt }
    func recordStopReceipt(_ receipt: RoverCommandDiagnosticReceipt) { stopReceipt = receipt }
    func failure(source: FollowMotionDeliverySource) -> FollowMotionFailureDelivery? {
        guard let primaryFailure else { return nil }
        return .init(context: context, reason: primaryFailure, stopOutcome: stopOutcome,
            source: source, stale: fenced, commandReceipt: commandReceipt, stopReceipt: stopReceipt)
    }
    func result(_ result: NavigationResult) -> FollowMotionResult {
        .init(result: result, context: context, failure: failure(source: .result),
            stopOutcome: stopOutcome, commandReceipt: commandReceipt, stopReceipt: stopReceipt,
            deferred: primaryFailure == nil && stopOutcome != .failed ? FollowReadyAdmissionScope.current?.deferred : nil)
    }
}

/// One stop invocation's immutable response, retained only until its waiter drains.
@MainActor
final class FollowMotionStopReceiptCapture {
    var receipt: RoverCommandDiagnosticReceipt?
}

enum FollowMotionTaskScope {
    @TaskLocal static var evidence: FollowMotionOperationEvidence?
    @TaskLocal static var stopReceiptCapture: FollowMotionStopReceiptCapture?
    @TaskLocal static var stopOrigin: FollowMotionStopOrigin = .independent
}

struct FollowScanRotationProfile: Sendable, Equatable {
    let pulseWait: TimeInterval
    let settleWait: TimeInterval
    let wheelCap: Double
    let yawGain: Double
    let angularTolerance: Double
    var wheelFloor: Double { wheelCap }
    var commandLaw: String { "fixed_signed_magnitude" }
    // Historical tuning metadata; fixed pulses do not use proportional gain.
    var yawGainActive: Bool { false }
}

/// Immutable correlation captured at the owning serialized boundary.
struct FollowDiagnosticContext: Sendable, Equatable {
    let sessionGeneration: UInt64?
    let operationID: UInt64?
    let purpose: String?
    let phase: String?
    let pulseIndex: Int?
    let stale: Bool
    let outcome: String?
    let reason: String?

    init(sessionGeneration: UInt64? = nil, operationID: UInt64? = nil,
         purpose: String? = nil, phase: String? = nil, pulseIndex: Int? = nil,
         stale: Bool = false, outcome: String? = nil, reason: String? = nil) {
        self.sessionGeneration = sessionGeneration
        self.operationID = operationID
        self.purpose = purpose
        self.phase = phase
        self.pulseIndex = pulseIndex
        self.stale = stale
        self.outcome = outcome
        self.reason = reason
    }
}

enum RotationPosePairing: String, Sendable, CaseIterable {
    case sameFrame = "same_frame"
    case independentlySampled = "independently_sampled"
    case unknown
}

struct RotationPoseDiagnosticSample: Sendable {
    let yaw: Double?
    let readMonotonic: Double
    let trackingState: String?
    let frameID: String?
    let observationAge: Double?
    let pairing: RotationPosePairing
    let sourceTimestamp: Double?
    let sourceGeneration: UInt64?
    let sourceAge: Double?
    let sourceIdentity: String?
    let sourceAvailability: String?

    init(yaw: Double?, readMonotonic: Double, trackingState: String? = nil,
          frameID: String? = nil, observationAge: Double? = nil, pairing: RotationPosePairing = .unknown,
          sourceTimestamp: Double? = nil, sourceGeneration: UInt64? = nil, sourceAge: Double? = nil,
          sourceIdentity: String? = nil, sourceAvailability: String? = nil) {
        self.yaw = yaw
        self.readMonotonic = readMonotonic
        self.trackingState = trackingState
        self.frameID = frameID
        self.observationAge = observationAge
        self.pairing = pairing
        self.sourceTimestamp = sourceTimestamp
        self.sourceGeneration = sourceGeneration
        self.sourceAge = sourceAge
        self.sourceIdentity = sourceIdentity
        self.sourceAvailability = sourceAvailability
    }

    init(sample: NavigationPoseSample, uptime: Double, expectedGeneration: UInt64?) {
        self.init(yaw: sample.pose?.yaw, readMonotonic: uptime,
            trackingState: sample.trackingQuality.map { String(describing: $0) },
            frameID: sample.frameID.map { "\($0.generation):\($0.sequence)" },
            sourceTimestamp: sample.sourceTimestamp, sourceGeneration: sample.frameID?.generation,
            sourceAge: sample.sourceTimestamp.map { uptime - $0 }, sourceIdentity: sample.source,
            sourceAvailability: sample.rejection(at: uptime, expectedGeneration: expectedGeneration) ?? "available")
    }

    var finiteYaw: Double? { yaw.flatMap { $0.isFinite ? $0 : nil } }
    var availability: String { yaw == nil ? "unavailable" : (finiteYaw == nil ? "nonfinite" : "available") }
}

struct RotationDiagnosticMeasurement: Sendable {
    let pre: RotationPoseDiagnosticSample?
    let post: RotationPoseDiagnosticSample?
    let targetYaw: Double?
    private var finiteTarget: Double? { targetYaw.flatMap { $0.isFinite ? $0 : nil } }
    private var preError: Double? {
        guard let target = finiteTarget, let yaw = pre?.finiteYaw else { return nil }
        return Self.normalize(target - yaw)
    }
    private var postError: Double? {
        guard let target = finiteTarget, let yaw = post?.finiteYaw else { return nil }
        return Self.normalize(target - yaw)
    }
    var errorImprovement: Double? {
        guard let before = preError, let after = postError else { return nil }
        return abs(before) - abs(after)
    }
    var payload: [String: FollowDiagnosticValue] {
        let metadata = post ?? pre
        let pairing: RotationPosePairing
        if let before = pre?.frameID, let after = post?.frameID {
            pairing = before == after ? .sameFrame : .independentlySampled
        } else { pairing = metadata?.pairing ?? .unknown }
        var result: [String: FollowDiagnosticValue] = [
            "pose_source_timestamp": metadata?.sourceTimestamp.map { .number($0) } ?? .null,
            "pose_source_age_status": .string(metadata?.sourceAge.map { $0.isFinite ? "available" : "nonfinite" } ?? "unknown"),
            "pose_pairing": .string(pairing.rawValue),
            "pose_pairing_scope": .string("controller_pre_post"),
            "pose_source_clock": .string(metadata?.sourceTimestamp == nil ? "unknown" : "ar_system_uptime"),
            "pose_read_clock": .string(metadata?.sourceIdentity == nil ? "host_monotonic" : "ar_system_uptime"),
            "tracking_state": metadata?.trackingState.map { .string($0) } ?? .null,
            "tracking_state_availability": .string(metadata?.trackingState == nil ? "unknown" : "available"),
            "perception_frame_id": metadata?.frameID.map { .string($0) } ?? .null,
            "perception_frame_id_availability": .string(metadata?.frameID == nil ? "unknown" : "available"),
            "observation_age_s": metadata?.observationAge.map { .number($0) } ?? .null,
            "observation_age_s_availability": .string(metadata?.observationAge == nil ? "unknown" : "available"),
            "yaw_measurement_source": .string("ar_visual_inertial"),
            "duration_clock": .string("host_monotonic"),
            "pre_pose_availability": .string(pre?.availability ?? "unavailable"),
            "post_pose_availability": .string(post?.availability ?? "unavailable"),
            "pre_pose_read_monotonic_s": pre.map { .number($0.readMonotonic) } ?? .null,
            "post_pose_read_monotonic_s": post.map { .number($0.readMonotonic) } ?? .null
        ]
        for (prefix, sample) in [("pre", pre), ("post", post)] {
            result[prefix + "_source_frame_id"] = sample?.frameID.map { .string($0) } ?? .null
            result[prefix + "_source_generation"] = sample?.sourceGeneration.map { .number(Double($0)) } ?? .null
            result[prefix + "_source_timestamp_s"] = sample?.sourceTimestamp.map { .number($0) } ?? .null
            result[prefix + "_source_age_s"] = sample?.sourceAge.map { .number($0) } ?? .null
            result[prefix + "_source_identity"] = sample?.sourceIdentity.map { .string($0) } ?? .null
            result[prefix + "_tracking_state"] = sample?.trackingState.map { .string($0) } ?? .null
            result[prefix + "_source_availability"] = .string(sample?.sourceAvailability ?? "unknown")
        }
        let delta: Double?
        if let before = pre?.finiteYaw, let after = post?.finiteYaw {
            delta = Self.normalize(after - before)
        } else { delta = nil }
        let angles: [String: Double?] = [
            "pre_yaw_rad": pre?.finiteYaw, "post_yaw_rad": post?.finiteYaw,
            "target_yaw_rad": finiteTarget, "pre_error_rad": preError,
            "post_error_rad": postError, "signed_yaw_delta_rad": delta,
            "error_improvement_rad": errorImprovement
        ]
        for (key, value) in angles {
            let finite = value.flatMap { $0.isFinite ? $0 : nil }
            result[key] = finite.map { .number($0) } ?? .null
            result[key + "_display"] = finite.map { .string(Self.angleDisplay($0)) } ?? .null
            result[key + "_availability"] = .string(finite == nil ? "unavailable" : "available")
        }
        return result
    }
    static func normalize(_ angle: Double) -> Double {
        guard angle.isFinite else { return .nan }
        let period = 2 * Double.pi
        var value = angle.truncatingRemainder(dividingBy: period)
        if value >= .pi { value -= period }
        if value < -.pi { value += period }
        return value
    }
    static func angleDisplay(_ angle: Double) -> String {
        String(format: "%+.6f", locale: Locale(identifier: "en_US_POSIX"), angle)
    }
}
