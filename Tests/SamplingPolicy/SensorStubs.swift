// Snapshot regressions exercise the production connection and presentation
// code without opening IOKit or constructing a UI application.
nonisolated enum ThermalZone: Hashable {
    case battery, charger, soc, other
    var order: Int { 0 }
}

nonisolated enum SensorCatalog {
    static func zone(for name: String) -> ThermalZone { .other }
}

nonisolated enum HIDSensors {
    enum Kind: Hashable { case temperature, voltage, current }
    struct Reading: Hashable {
        let name: String
        let kind: Kind
        let value: Double
    }
    static let plausibleCelsius = -20.0...120.0
}
