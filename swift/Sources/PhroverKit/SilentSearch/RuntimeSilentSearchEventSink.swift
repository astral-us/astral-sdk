import Foundation

@MainActor
public final class RuntimeSilentSearchEventSink: SilentSearchEventSink {
    public init() {}

    public func record(event: String, fields: [String: String]) {
        RuntimeFileLog.append(event, fields: fields)
    }
}
