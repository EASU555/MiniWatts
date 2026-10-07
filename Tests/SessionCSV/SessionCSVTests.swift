import Foundation

// Compile the real energy/session models while keeping sensor and UIKit code out.
nonisolated struct PowerSnapshot {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
    let batteryCurrent: Double?
}

@main struct SessionCSVTests {
    static let headers = [
        "record_type", "metadata_key", "metadata_value", "timestamp_utc",
        "offset_seconds", "input_watts", "battery_watts", "battery_percent",
        "battery_temperature_c", "hottest_temperature_c", "system_thermal_throttling",
        "starts_new_segment"
    ]

    static func fixture() -> ChargeSession {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.date(from: "2026-10-06T23:59:58.125Z")!
        var session = ChargeSession(start: start, startPercent: nil,
                                    adapterName: " Acme, \"Power\"\r\n=ignored",
                                    adapterRatedWatts: 25.5, isWireless: false)
        session.end = start.addingTimeInterval(90)
        session.endPercent = 0
        session.samples = [
            ChargeSample(offset: 5, inputWatts: nil, batteryWatts: 0, percent: nil,
                         batteryTemperature: nil, hottestTemperature: 0, throttled: false,
                         startsNewSegment: true),
            ChargeSample(offset: 0, inputWatts: 12.25, batteryWatts: -0.25, percent: 0,
                         batteryTemperature: 35.5, hottestTemperature: 38, throttled: true),
            ChargeSample(offset: 10, inputWatts: 0, batteryWatts: nil, percent: 80,
                         batteryTemperature: nil, hottestTemperature: nil, throttled: false,
                         startsNewSegment: false)
        ]
        return session
    }

    /// An independent UTF-8 RFC 4180 reader: embedded commas, CRLF and doubled
    /// quotes must round-trip through cells instead of creating extra records.
    static func parse(_ csv: String) -> [[String]] {
        let bytes = Array(csv.utf8)
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                if quoted && index + 1 < bytes.count && bytes[index + 1] == 34 {
                    field.append(34)
                    index += 1
                } else {
                    if !quoted { precondition(field.isEmpty, "Quote must begin a field") }
                    quoted.toggle()
                }
            } else if !quoted && byte == 44 {
                row.append(String(decoding: field, as: UTF8.self))
                field = []
            } else if !quoted && (byte == 10 || byte == 13) {
                row.append(String(decoding: field, as: UTF8.self))
                rows.append(row)
                row = []
                field = []
                if byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 { index += 1 }
            } else {
                field.append(byte)
            }
            index += 1
        }
        precondition(!quoted, "Unclosed quoted CSV cell")
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            rows.append(row)
        }
        precondition(rows.first == headers, "Unexpected CSV schema")
        precondition(rows.allSatisfy { $0.count == headers.count }, "CSV records are not rectangular")
        return rows
    }

    static func metadata(_ rows: [[String]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rows.filter { $0[0] == "metadata" }.map { ($0[1], $0[2]) })
    }

    static func checkMeasurements() throws {
        var session = fixture()
        // A stale raw total without coverage must not become a claimed reading.
        session.totals.batteryWattHours = 9
        session.totals.inputIntegratedSeconds = 5
        session.totals.integratedSeconds = 5
        let csv = try SessionCSVExporter.csv(for: session)
        let rows = parse(csv)
        let info = metadata(rows)
        let samples = rows.filter { $0[0] == "sample" }
        precondition(info["schema_version"] == "1")
        precondition(info["session_id"] == session.id.uuidString)
        precondition(info["session_start_utc"] == "2026-10-06T23:59:58.125Z")
        precondition(info["session_end_utc"] == "2026-10-07T00:01:28.125Z")
        precondition(info["session_elapsed_seconds"] == "90.0")
        precondition(info["session_start_battery_percent"] == "")
        precondition(info["session_end_battery_percent"] == "0")
        precondition(info["session_gained_battery_percent"] == "")
        precondition(info["adapter_name"] == session.adapterName)
        precondition(info["adapter_rated_watts"] == "25.5")
        precondition(info["is_wireless"] == "0")
        precondition(info["nominal_sample_interval_seconds"] == "5.0")
        precondition(info["recorded_sample_count"] == "3")
        precondition(info["measured_input_watt_hours"] == "0")
        precondition(info["measured_battery_watt_hours"] == "")
        precondition(info["measured_battery_milliamp_hours"] == "")
        precondition(info["measured_paired_input_watt_hours"] == "")
        precondition(info["input_to_cell_percent"] == "")
        precondition(info["input_power_covered_seconds"] == "5.0")
        precondition(info["sampling_note"]!.contains("may be thinned"))
        precondition(info["sampling_note"]!.contains("not extrapolated"))
        precondition(info["segment_marker_note"]!.contains("Legacy records have no reliable gap marker"))
        precondition(samples.map { $0[4] } == ["5.0", "0", "10.0"], "Sample order changed")
        precondition(samples[0][3] == "2026-10-07T00:00:03.125Z")
        precondition(Array(samples[0][5...11]) == ["", "0", "", "", "0", "0", "1"])
        precondition(Array(samples[1][5...11]) == ["12.25", "-0.25", "0", "35.5", "38.0", "1", "0"])
        precondition(Array(samples[2][5...11]) == ["0", "", "80", "", "", "0", "0"])
        precondition(csv.hasSuffix("\r\n"))
        precondition(csv.contains("\" Acme, \"\"Power\"\"\r\n=ignored\""))
        let repeated = try SessionCSVExporter.csv(for: session)
        precondition(repeated == csv, "Text export is not deterministic")

        session.totals.pairedIntegratedSeconds = 5
        session.totals.pairedInputWattHours = 1
        session.totals.pairedBatteryWattHours = 0
        let paired = metadata(parse(try SessionCSVExporter.csv(for: session)))
        precondition(paired["measured_paired_battery_watt_hours"] == "0")
        precondition(paired["input_to_cell_percent"] == "0")
        precondition(paired["measured_not_to_cell_watt_hours"] == "1.0")
        print("PASS: UTC, original order, measured zero, missing values and paired coverage")
    }

    static func checkEscapingAndSafety() throws {
        var session = fixture()
        for name in ["=SUM(1,2)", "+1+2", "-1+2", "@SUM(A1)", " \t=cmd", "\tadapter", "\radapter", "\nadapter", "\r\nadapter"] {
            session.adapterName = name
            let info = metadata(parse(try SessionCSVExporter.csv(for: session)))
            precondition(info["adapter_name"] == "'" + name, "Unsafe adapter text was not escaped")
        }
        for name in ["USB-C", "充电器, \"25W\"", "Acme\n第二行"] {
            session.adapterName = name
            let info = metadata(parse(try SessionCSVExporter.csv(for: session)))
            precondition(info["adapter_name"] == name, "Ordinary raw adapter text changed")
        }
        session.adapterRatedWatts = .infinity
        session.samples = [ChargeSample(offset: 0, inputWatts: .nan, batteryWatts: .infinity,
                                       percent: nil, batteryTemperature: -.infinity,
                                       hottestTemperature: .nan, throttled: false)]
        let rows = parse(try SessionCSVExporter.csv(for: session))
        let sample = rows.first { $0[0] == "sample" }!
        precondition(sample[5...9].allSatisfy(\.isEmpty))
        precondition(metadata(rows)["adapter_rated_watts"] == "")
        print("PASS: RFC 4180 Unicode/comma/quote/newline escaping and formula-safe adapter text")
    }

    static func checkMigration() throws {
        var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as! [String: Any]
        record["startPercent"] = 0
        record["endPercent"] = 0
        var samples = record["samples"] as! [[String: Any]]
        for index in samples.indices { samples[index].removeValue(forKey: "startsNewSegment") }
        samples[0].removeValue(forKey: "percent")
        samples[1]["percent"] = 0
        record["samples"] = samples
        record["totals"] = ["inputWattHours": 0, "batteryWattHours": 0,
                            "batteryMilliAmpHours": 0, "integratedSeconds": 5]
        let legacy = try JSONDecoder().decode(ChargeSession.self,
                                             from: JSONSerialization.data(withJSONObject: record))
        let rows = parse(try SessionCSVExporter.csv(for: legacy))
        let info = metadata(rows)
        let points = rows.filter { $0[0] == "sample" }
        precondition(info["session_start_battery_percent"] == "0")
        precondition(info["session_end_battery_percent"] == "0")
        precondition(info["session_gained_battery_percent"] == "0")
        precondition(info["measured_input_watt_hours"] == "0")
        precondition(info["paired_power_covered_seconds"] == "0")
        precondition(info["input_to_cell_percent"] == "")
        precondition(points[0][7] == "" && points[1][7] == "0")
        precondition(points.allSatisfy { $0[11] == "0" })

        record.removeValue(forKey: "startPercent")
        record["endPercent"] = NSNull()
        let missing = try JSONDecoder().decode(ChargeSession.self,
                                              from: JSONSerialization.data(withJSONObject: record))
        let missingInfo = metadata(parse(try SessionCSVExporter.csv(for: missing)))
        precondition(missingInfo["session_start_battery_percent"] == "")
        precondition(missingInfo["session_end_battery_percent"] == "")
        precondition(missingInfo["session_gained_battery_percent"] == "")
        print("PASS: legacy stored zero remains zero; missing/null percentage and gap markers stay unavailable")
    }

    static func checkWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = fixture()
        let destination = root.appendingPathComponent("nested/exports", isDirectory: true)
        async let first = SessionCSVExporter.export(session, directory: destination)
        async let second = SessionCSVExporter.export(session, directory: destination)
        let (firstURL, secondURL) = try await (first, second)
        let urls = [firstURL, secondURL]
        precondition(urls[0] != urls[1], "Repeated export must create unique files")
        let expected = try SessionCSVExporter.csv(for: session)
        for url in urls {
            precondition(url.pathExtension == "csv")
            precondition(url.lastPathComponent.contains(session.id.uuidString))
            let contents = try String(contentsOf: url, encoding: .utf8)
            precondition(contents == expected)
        }
        let files = try FileManager.default.contentsOfDirectory(at: destination,
                                                               includingPropertiesForKeys: nil)
        precondition(Set(files) == Set(urls), "Atomic writer left an unexpected file")

        let blocker = root.appendingPathComponent("blocked")
        try Data("keep this file".utf8).write(to: blocker)
        do {
            _ = try await SessionCSVExporter.export(session, directory: blocker)
            preconditionFailure("Filesystem export error did not reach its caller")
        } catch {
            precondition(!(error is SessionCSVExporter.ExportError))
            let preserved = try Data(contentsOf: blocker)
            precondition(preserved == Data("keep this file".utf8))
        }

        var open = session
        open.end = nil
        do {
            _ = try SessionCSVExporter.csv(for: open)
            preconditionFailure("An open session fabricated an end date")
        } catch SessionCSVExporter.ExportError.sessionStillOpen {}
        let unopened = root.appendingPathComponent("must-not-be-created")
        do {
            _ = try await SessionCSVExporter.export(open, directory: unopened)
            preconditionFailure("An open session wrote a file")
        } catch SessionCSVExporter.ExportError.sessionStillOpen {}
        precondition(!FileManager.default.fileExists(atPath: unopened.path))

        var invalid = session
        invalid.end = session.start.addingTimeInterval(-1)
        do {
            _ = try SessionCSVExporter.csv(for: invalid)
            preconditionFailure("Invalid session dates were accepted")
        } catch SessionCSVExporter.ExportError.invalidSessionDates {}
        print("PASS: unique atomic files, propagated I/O errors and finished-session validation")
    }

    static func main() async throws {
        try checkMeasurements()
        try checkEscapingAndSafety()
        try checkMigration()
        try await checkWriter()
    }
}
