import XCTest
@testable import PhroverKit

final class RoverControlTests: XCTestCase {
    func testUnknownReceiptDoesNotClaimTransportFacts() {
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.httpStatus)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.acknowledged)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.acknowledgementUTC)
        XCTAssertNil(RoverCommandDiagnosticReceipt.unknown.attempts)
        XCTAssertEqual(RoverCommandDiagnosticReceipt.unknown.outcome, "unknown")
    }

    func testReceiptsPreserveRealAcceptedStatusAndAckClock() async throws {
        for status in [200, 204, 299] {
            StubURLProtocol.reset()
            StubURLProtocol.results = [.success((Data(), HTTPURLResponse(
                url: URL(string: "http://192.168.4.1/js")!, statusCode: status,
                httpVersion: nil, headerFields: nil)!))]
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let result = await control.sendNavigationWithReceipt(.init(left: -0.1, right: 0.1))
            XCTAssertNil(result.failure)
            XCTAssertEqual(result.receipt.httpStatus, status)
            XCTAssertEqual(result.receipt.acknowledged, true)
            XCTAssertEqual(result.receipt.attempts, 1)
            let ack = await control.lastAckAt
            XCTAssertEqual(result.receipt.acknowledgementUTC, ack)
            XCTAssertNotNil(ack)
        }
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFailureReceiptsKeepActualStatusAttemptsAndOriginalErrors() async throws {
        let url = URL(string: "http://192.168.4.1/js")!
        let cases: [(Result<(Data, URLResponse), Error>, Int?, Int, String)] = [
            (.success((Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!)), 503, 1, "failed"),
            (.success((Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))), nil, 1, "failed"),
            (.failure(URLError(.timedOut)), nil, 3, "failed"),
            (.failure(URLError(.cancelled)), nil, 1, "cancelled")
        ]
        for (response, status, attempts, outcome) in cases {
            StubURLProtocol.reset()
            StubURLProtocol.results = Array(repeating: response, count: attempts)
            let control = RoverControl(session: URLSession(configuration: .stubbed))
            let result = await control.sendNavigationWithReceipt(.init(left: -0.1, right: 0.1))
            XCTAssertNotNil(result.failure)
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(result.receipt.httpStatus, status)
            XCTAssertEqual(result.receipt.attempts, attempts)
            XCTAssertEqual(result.receipt.outcome, outcome)
            XCTAssertEqual(result.receipt.acknowledged, false)
            XCTAssertNil(result.receipt.acknowledgementUTC)
            XCTAssertEqual(StubURLProtocol.requestCount, attempts)
            let ack = await control.lastAckAt
            XCTAssertNil(ack)
        }
    }

    func testStopAndRetryReceiptsDescribeTheirOwnAcknowledgement() async throws {
        StubURLProtocol.results = [.failure(URLError(.timedOut)), .success((Data(), HTTPURLResponse(
            url: URL(string: "http://192.168.4.1/js")!, statusCode: 204, httpVersion: nil, headerFields: nil)!))]
        let control = RoverControl(session: URLSession(configuration: .stubbed))
        let result = await control.stopWithReceipt()
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.receipt.httpStatus, 204)
        XCTAssertEqual(result.receipt.attempts, 2)
        XCTAssertEqual(result.receipt.acknowledged, true)
        XCTAssertEqual(result.receipt.outcome, "acknowledged")
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["T"] as? Int, 0)
        XCTAssertNil(payload["L"])
    }

    func testRetriesTransientCommandTimeoutBeforeFailingNavigationLink() async throws {
        StubURLProtocol.results = [
            .failure(URLError(.timedOut)),
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }

    func testDoesNotRetryServerErrors() async {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 500,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        do {
            try await control.send(.init(left: 0.1, right: 0.1))
            XCTFail("Expected server error")
        } catch RoverControlError.serverError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected server error, got \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testRetriesTwoTransientTimeoutsBeforeFailingNavigationLink() async throws {
        StubURLProtocol.results = [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.requestCount, 3)
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }

    func testRequestLogFieldsIncludeURLAndHTTPStatus() {
        let fields = RoverControl.requestLogFields(url: URL(string: "http://192.168.4.1/js?json=%7B%7D")!,
                                                   attempt: 2,
                                                   maxAttempts: 3,
                                                   statusCode: 200,
                                                   error: nil)

        XCTAssertEqual(fields["url"], "http://192.168.4.1/js?json=%7B%7D")
        XCTAssertEqual(fields["attempt"], "2")
        XCTAssertEqual(fields["max"], "3")
        XCTAssertEqual(fields["status"], "200")
        XCTAssertNil(fields["error"])
    }

    func testCommandRequestsDisableStaleConnectionReuse() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: 0.1, right: 0.1))

        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Connection"), "close")
        XCTAssertEqual(StubURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testCommandMapsNavigationYawToWaveRoverWheelDirection() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.sendNavigation(.init(left: -0.25, right: 0.25))

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["L"] as? Double, 0.25)
        XCTAssertEqual(payload["R"] as? Double, -0.25)
    }

    func testManualCommandPreservesPhysicalWheelDirection() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 200,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let session = URLSession(configuration: .stubbed)
        let control = RoverControl(session: session)

        try await control.send(.init(left: -0.25, right: 0.25))

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["L"] as? Double, -0.25)
        XCTAssertEqual(payload["R"] as? Double, 0.25)
    }

    func testProbeLinkUsesFeedbackFlowCommandAndRefreshesAcknowledgement() async throws {
        StubURLProtocol.results = [
            .success((Data(), HTTPURLResponse(url: URL(string: "http://192.168.4.1/js")!,
                                              statusCode: 204,
                                              httpVersion: nil,
                                              headerFields: nil)!))
        ]
        let control = RoverControl(session: URLSession(configuration: .stubbed))

        try await control.probeLink()

        let requestURL = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        let json = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "json" })?.value)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(payload["T"] as? Int, 131)
        XCTAssertEqual(payload["cmd"] as? Int, 1)
        XCTAssertNil(payload["L"])
        XCTAssertNil(payload["R"])
        let lastAckAt = await control.lastAckAt
        XCTAssertNotNil(lastAckAt)
    }
}

private extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var results: [Result<(Data, URLResponse), Error>] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        results = []
        requestCount = 0
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        guard !Self.results.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch Self.results.removeFirst() {
        case .success(let result):
            client?.urlProtocol(self, didReceive: result.1, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.0)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
