import Foundation

@main struct RecorderTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = ProblemReportRecorder(directory: root)
        recorder.record("pip", "温度小窗启动")
        let marked = try await recorder.markIssue()
        check(marked <= .now, "Marker must have a real timestamp")
        recorder.record("activity", "update timed out before export")
        let first = try await recorder.export(summary: "test device, version 1", note: "灵动岛消失了")
        let firstText = try String(contentsOf: first.url, encoding: .utf8)
        check(firstText.contains("温度小窗启动"), "Unicode event lost")
        check(firstText.contains("USER_MARK"), "Marker not persisted before confirmation")
        check(firstText.contains("update timed out before export"), "Export overtook queued records")
        check(firstText.contains("灵动岛消失了"), "User description missing")
        print("PASS: ordered persistence, confirmed marker, Unicode and report description")

        // A fresh instance sees only disk state, as a new app process does.
        let reopened = ProblemReportRecorder(directory: root)
        let next = try await reopened.export(summary: "new launch", note: "")
        let previous = try String(contentsOf: root.appendingPathComponent("previous.log"), encoding: .utf8)
        check(previous.contains("USER_MARK"), "Previous launch marker was lost")
        check(previous.contains("update timed out"), "Previous launch failure was lost")
        let nextText = try String(contentsOf: next.url, encoding: .utf8)
        check(nextText.contains(previous), "Export omitted previous run")
        print("PASS: previous run survives recreation without a shutdown callback")

        for index in 0..<1400 {
            reopened.record("rotation", "event-\(index) " + String(repeating: "测", count: 550))
        }
        reopened.record("rotation", "retained-tail-sentinel")
        let rotated = try await reopened.export(summary: "bounded", note: String(repeating: "x", count: 5000))
        let rotatedText = try String(contentsOf: rotated.url, encoding: .utf8)
        check(rotatedText.contains("retained-tail-sentinel"), "Newest data lost on rotation")
        check(!rotatedText.contains("event-0 "), "Oldest current-run events never rotate")
        for name in ["current.log", "current-older.log"] {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            check(bytes.count <= ProblemReportRecorder.segmentLimit, "Segment exceeded limit")
            check(String(data: bytes, encoding: .utf8) != nil, "Rotation broke a UTF-8 record")
        }
        check(rotated.preview.count <= 24000, "Preview is unbounded")
        check(rotatedText.utf8.count < 1_100_000, "Report exceeded normal storage bound")
        for _ in 0..<5 { _ = try await reopened.export(summary: "latest", note: "") }
        let exports = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Exports"), includingPropertiesForKeys: nil)
        check(exports.count == 3, "Temporary exports accumulated indefinitely")
        print("PASS: bounded Unicode rotation, notes, preview and export retention")

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        let unavailable = ProblemReportRecorder(directory: blocked)
        do {
            _ = try await unavailable.markIssue()
            preconditionFailure("Failed marker falsely reported success")
        } catch {}
        do {
            _ = try await unavailable.export(summary: "test", note: "")
            preconditionFailure("Failed export falsely reported success")
        } catch {}
        print("PASS: write failures reach the caller")
    }
}
