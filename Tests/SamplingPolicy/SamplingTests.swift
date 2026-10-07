import Foundation

nonisolated struct SamplingHarness {
    var gate = SensorSamplingGate()
    private(set) var reads = 0
    private(set) var publications = 0

    mutating func callback() -> Int? {
        guard let generation = gate.beginRead() else { return nil }
        reads += 1
        return generation
    }

    mutating func complete(_ generation: Int) {
        if gate.finishRead(generation: generation) { publications += 1 }
    }
}

@main struct SamplingTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() throws {
        var harness = SamplingHarness()
        check(harness.callback() == nil, "A callback before start launched a read")
        harness.gate.start()
        let first = harness.callback()!
        check(harness.callback() == nil, "Two drivers overlapped sensor reads")
        harness.complete(first)
        check(harness.publications == 1, "The active read was not published")

        let pausedRead = harness.callback()!
        harness.gate.pause()
        check(harness.callback() == nil, "Queued battery callback read after pause")
        check(harness.callback() == nil, "Queued PiP callback read after pause")
        harness.complete(pausedRead)
        check(harness.publications == 1, "A blocked read published after pause")
        check(harness.reads == 2, "Paused callbacks reached the probe")

        harness.gate.start()
        let interrupted = harness.callback()!
        harness.gate.pause()
        harness.gate.start()
        check(harness.callback() == nil, "Restart overlapped the retiring read")
        harness.complete(interrupted)
        check(harness.publications == 1, "Restart accepted a pre-pause result")
        let resumed = harness.callback()!
        harness.complete(resumed)
        check(harness.publications == 2, "An adjacent restarted read was lost")
        print("PASS: paused callbacks, discarded reads, overlap prevention and restart")

        let missing = PowerSnapshot()
        check(missing.externalConnectionObservation == nil,
              "No source data was reported as an unplug")
        check(SamplingSessionAction.decide(externalConnection: nil) == .hold,
              "Missing evidence closes a charging session")
        check(SamplingSessionAction.decide(externalConnection: true) == .record,
              "A confirmed charger does not record")
        check(SamplingSessionAction.decide(externalConnection: false) == .close,
              "An observed unplug does not close")

        let ac = PowerSnapshot(powerSource: ["Power Source State": "AC Power"])
        let battery = PowerSnapshot(powerSource: ["Power Source State": "Battery Power"])
        let unrecognized = PowerSnapshot(powerSource: ["Power Source State": "unavailable"])
        check(ac.externalConnectionObservation == true, "AC state was not recognized")
        check(battery.externalConnectionObservation == false, "Battery state was not recognized")
        check(unrecognized.externalConnectionObservation == nil,
              "An unrecognized state invented an unplug")
        let raw = PowerSnapshot(powerSource: ["Raw External Connected": false])
        check(raw.externalConnectionObservation == false, "Explicit raw false was lost")
        let registry = PowerSnapshot(registry: ["ExternalConnected": true],
                                     powerSource: ["Power Source State": "Battery Power"])
        check(registry.externalConnectionObservation == true, "Registry precedence changed")
        let malformed = PowerSnapshot(registry: ["ExternalConnected": "unavailable"],
                                      powerSource: ["Power Source State": "AC Power"])
        check(malformed.externalConnectionObservation == true,
              "Malformed registry data blocked a valid fallback")
        print("PASS: unknown, AC, battery, raw fallback and registry precedence")

        let unavailablePower = PowerSnapshot(registry: ["Voltage": 4_000,
                                                        "InstantAmperage": -500])
        let unavailableReading = ChargeReading(unavailablePower)
        check(unavailablePower.batteryWatts == -2, "Raw battery formula changed")
        check(unavailableReading.externalConnectionObservation == nil,
              "Compact data erased an unknown connection")
        check(unavailableReading.watts == nil && unavailableReading.source == nil,
              "Unknown external power was presented as discharge watts")
        let disconnectedPower = PowerSnapshot(registry: ["Voltage": 4_000,
                                                         "InstantAmperage": -500,
                                                         "ExternalConnected": false])
        let disconnectedReading = ChargeReading(disconnectedPower)
        check(disconnectedReading.watts == 2 && disconnectedReading.source == .fromBattery,
              "A measured discharge lost its existing presentation")
        let connectedPower = PowerSnapshot(registry: ["Voltage": 4_000,
                                                      "InstantAmperage": 500,
                                                      "ExternalConnected": true])
        let connectedReading = ChargeReading(connectedPower)
        check(connectedReading.watts == 2 && connectedReading.source == .intoBattery,
              "A measured battery-side charge lost its existing presentation")

        let encoded = try JSONEncoder().encode(unavailableReading)
        let restored = try JSONDecoder().decode(ChargeReading.self, from: encoded)
        check(restored.externalConnectionObservation == nil,
              "Encoding lost the unknown connection state")
        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(disconnectedReading)) as! [String: Any]
        legacy.removeValue(forKey: "externalConnectionUnavailable")
        let legacyReading = try JSONDecoder().decode(ChargeReading.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        check(legacyReading.externalConnectionObservation == false,
              "Existing widget JSON was incorrectly classified as unavailable")
        print("PASS: unavailable watts, preserved measured formulas and legacy widget JSON")
    }
}
