import Foundation

final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestURLs: [URL] = []

    static func reset() {
        delay = 0
        requestCount = 0
        requestURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.requestURLs.append(request.url!)
        let request = request
        let delay = Self.delay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                  ) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
