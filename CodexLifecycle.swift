import Foundation

// Track actual Codex turns instead of cmux's potentially stale hook status.
struct CodexLifecycle {
    static let completedDisplaySeconds: TimeInterval = 10
    var turn: String?
    var state = "unknown"
    var doneAt: Date?
    mutating func consume(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              event["type"] as? String == "event_msg",
              let payload = event["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        let id = payload["turn_id"] as? String
        switch type {
        case "task_started":
            turn = id; state = "running"; doneAt = nil
        case "task_complete", "task_completed", "turn_aborted":
            if turn == nil || id == nil || id == turn { turn = nil; state = "done"; doneAt = Date() }
        default: break
        }
    }
    func currentState(now: Date = Date()) -> String {
        if state == "done", let doneAt, now.timeIntervalSince(doneAt) >= Self.completedDisplaySeconds { return "idle" }
        return state
    }
}

final class CodexLogReader {
    struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var lifecycle = CodexLifecycle()
    }
    var cursors: [String: Cursor] = [:]
    func state(at path: String) -> String {
        guard let file = FileHandle(forReadingAtPath: path) else { return "unknown" }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            var cursor = cursors[path] ?? Cursor()
            if size < cursor.offset { cursor = Cursor() }
            try file.seek(toOffset: cursor.offset)
            while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                cursor.pending.append(chunk)
                while let newline = cursor.pending.firstIndex(of: 10) {
                    let line = cursor.pending.prefix(upTo: newline)
                    // Ignore message content: only parse lifecycle event records.
                    if line.range(of: Data("\"event_msg\"".utf8)) != nil {
                        cursor.lifecycle.consume(Data(line))
                    }
                    cursor.pending.removeSubrange(...newline)
                }
            }
            cursors[path] = cursor
            return cursor.lifecycle.currentState()
        } catch { return "unknown" }
    }
}
let codexLogs = CodexLogReader()
