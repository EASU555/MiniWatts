import Foundation

/// A rectangular, versioned CSV containing one finished session and its recorded
/// samples. This exports stored measurements; it never reconstructs missing ones.
nonisolated enum SessionCSVExporter {
    enum ExportError: Error, LocalizedError, Equatable, Sendable {
        case sessionStillOpen
        case invalidSessionDates

        var errorDescription: String? {
            switch self {
            case .sessionStillOpen:
                String(localized: "Finish this charging session before exporting its CSV.")
            case .invalidSessionDates:
                String(localized: "This charging session has invalid dates and cannot be exported.")
            }
        }
    }

    private static let queue = DispatchQueue(label: "org.zhaohe.MiniWatts.session-csv", qos: .utility)
    private static let columns = [
        "record_type", "metadata_key", "metadata_value", "timestamp_utc",
        "offset_seconds", "input_watts", "battery_watts", "battery_percent",
        "battery_temperature_c", "hottest_temperature_c", "system_thermal_throttling",
        "starts_new_segment"
    ]

    /// Builds deterministic UTF-8 CSV text. Both metadata and sample records have
    /// the same columns, so an RFC 4180 reader can import the whole file as a table.
    static func csv(for session: ChargeSession) throws -> String {
        guard let end = session.end else { throw ExportError.sessionStillOpen }
        guard session.start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite, end >= session.start else {
            throw ExportError.invalidSessionDates
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let totals = session.totals
        var rows = [columns]

        func metadata(_ key: String, _ value: String) {
            rows.append(["metadata", key, value] + Array(repeating: "", count: columns.count - 3))
        }

        metadata("schema", "MiniWatts.charge-session.csv")
        metadata("schema_version", "1")
        metadata("session_id", session.id.uuidString)
        metadata("session_start_utc", timestamp(session.start, formatter: formatter))
        metadata("session_end_utc", timestamp(end, formatter: formatter))
        metadata("session_elapsed_seconds", number(end.timeIntervalSince(session.start)))
        metadata("session_start_battery_percent", integer(session.startPercent))
        metadata("session_end_battery_percent", integer(session.endPercent))
        metadata("session_gained_battery_percent", integer(session.gainedPercent))
        metadata("adapter_name", spreadsheetText(session.adapterName ?? ""))
        metadata("adapter_rated_watts", number(session.adapterRatedWatts))
        metadata("is_wireless", flag(session.isWireless))
        metadata("recorded_sample_count", String(session.samples.count))
        metadata("nominal_sample_interval_seconds", number(SessionStore.sampleInterval))
        metadata("sampling_note", "Samples are recorded every \(number(SessionStore.sampleInterval)) seconds and may be thinned for long sessions. Original sample order is preserved. Missing readings stay blank; long or unavailable-sensor gaps are not extrapolated. Energy totals integrate live readings and are not recomputed from the retained CSV rows.")
        metadata("segment_marker_note", "starts_new_segment is 1 for an explicitly recorded break and 0 for unmarked or legacy rows. Legacy records have no reliable gap marker. Retained samples may be thinned, so timestamp gaps alone do not identify breaks; unknown intervals must not be interpolated.")
        metadata("spreadsheet_text_note", "Adapter text beginning with formula characters or control whitespace is prefixed with an apostrophe for spreadsheet safety. Numeric fields are unchanged.")
        metadata("integrated_observation_seconds", number(totals.integratedSeconds))
        metadata("input_power_covered_seconds", number(totals.inputIntegratedSeconds))
        metadata("battery_power_covered_seconds", number(totals.batteryIntegratedSeconds))
        metadata("battery_current_covered_seconds", number(totals.batteryCurrentIntegratedSeconds))
        metadata("paired_power_covered_seconds", number(totals.pairedIntegratedSeconds))
        metadata("measured_input_watt_hours", number(totals.measuredInputWattHours))
        metadata("measured_battery_watt_hours", number(totals.measuredBatteryWattHours))
        metadata("measured_battery_milliamp_hours", number(totals.measuredBatteryMilliAmpHours))
        metadata("measured_paired_input_watt_hours", number(totals.pairedIntegratedSeconds > 0 ? totals.pairedInputWattHours : nil))
        metadata("measured_paired_battery_watt_hours", number(totals.pairedIntegratedSeconds > 0 ? totals.pairedBatteryWattHours : nil))
        metadata("input_to_cell_percent", number(totals.inputToCellPercent))
        metadata("measured_not_to_cell_watt_hours", number(totals.measuredNotToCellWattHours))
        metadata("system_thermal_throttling_seconds", number(session.throttledSeconds))

        for sample in session.samples {
            rows.append([
                "sample", "", "",
                timestamp(session.start.addingTimeInterval(sample.offset), formatter: formatter),
                number(sample.offset), number(sample.inputWatts), number(sample.batteryWatts),
                integer(sample.percent), number(sample.batteryTemperature),
                number(sample.hottestTemperature), flag(sample.throttled),
                flag(sample.startsNewSegment == true)
            ])
        }

        return rows.map { $0.map(escaped).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Captures the Sendable value passed by the caller. Encoding and atomic file
    /// I/O run on a utility queue rather than the UI's main actor.
    static func export(_ session: ChargeSession) async throws -> URL {
        try await export(session, directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniWatts-Session-Exports", isDirectory: true))
    }

    /// The directory override keeps the real writer testable without UI or sensors.
    static func export(_ session: ChargeSession, directory: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let contents = try csv(for: session)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let filename = "MiniWatts-session-\(session.id.uuidString)-\(UUID().uuidString).csv"
                    let url = directory.appendingPathComponent(filename)
                    try Data(contents.utf8).write(to: url, options: .atomic)
                    continuation.resume(returning: url)
                } catch {
                    // Preserve native filesystem errors for the caller's alert.
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func timestamp(_ date: Date, formatter: ISO8601DateFormatter) -> String {
        guard date.timeIntervalSince1970.isFinite else { return "" }
        return formatter.string(from: date)
    }

    /// Swift's numeric description is locale independent. Reject corrupt nonfinite
    /// values and spell an observed zero as 0 rather than a missing field.
    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return value == 0 ? "0" : String(value)
    }

    private static func integer(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    private static func spreadsheetText(_ value: String) -> String {
        let trimmed = value.unicodeScalars.drop { $0.properties.isWhitespace || $0.value == 0xFEFF }
        let formulaPrefix = trimmed.first.map {
            $0.value == 61 || $0.value == 43 || $0.value == 45 || $0.value == 64
        } ?? false
        // Swift groups CRLF as one Character. Compare Unicode scalars so a
        // standalone CR/LF and a CRLF prefix all receive the same protection.
        let controlPrefix = value.unicodeScalars.first.map {
            $0.value == 9 || $0.value == 13 || $0.value == 10
        } ?? false
        return formulaPrefix || controlPrefix ? "'" + value : value
    }

    private static func escaped(_ value: String) -> String {
        // Delimiters are CSV code points, not extended graphemes. CRLF or a
        // comma followed by a combining mark must still cause the field to quote.
        guard value.unicodeScalars.contains(where: {
            $0.value == 44 || $0.value == 34 || $0.value == 13 || $0.value == 10
        }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
