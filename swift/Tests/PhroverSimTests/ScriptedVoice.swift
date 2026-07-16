import Foundation
import PhroverKit

/// `RoverVoice` for the sim: a scripted operator. `ask` pops the next queued reply (FIFO);
/// an empty queue simulates a timeout/no-reply, matching `RoverVoice.ask`'s documented
/// `nil`-on-timeout contract. Every speak/ask/reply is logged for scoring (capability #7's
/// ask-precision/recall metric reads this).
@MainActor
final class ScriptedVoice: RoverVoice {
    private var replyQueue: [String] = []
    private let events: EventLog

    init(events: EventLog, replies: [String] = []) {
        self.events = events
        self.replyQueue = replies
    }

    func enqueueReply(_ text: String) {
        replyQueue.append(text)
    }

    func speak(_ text: String) {
        events.log("speak", ["text": text])
    }

    func ask(_ question: String, timeout: TimeInterval) async -> String? {
        events.log("ask", ["question": question])
        guard !replyQueue.isEmpty else {
            events.log("ask_timeout", ["question": question])
            return nil
        }
        let reply = replyQueue.removeFirst()
        events.log("ask_reply", ["question": question, "reply": reply])
        return reply
    }
}
