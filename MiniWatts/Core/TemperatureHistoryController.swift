import Foundation
import Observation

/// Independently observable so normal one-second dashboard redraws do not also
/// rebuild a day-long chart. The history view subscribes to a five-second revision.
@Observable
final class TemperatureHistoryController {
    enum StorageState { case loading, ready, recovered, loadFailed, saveFailed, backupFailed }
    private(set) var storageState = StorageState.loading
    private(set) var revision = 0
    private(set) var latestRates: [String: Double] = [:]
    private(set) var storageDetail = ""
    private(set) var isRecording = false
    @ObservationIgnored private var recorder = TemperatureHistoryRecorder()
    @ObservationIgnored private let store: TemperatureHistoryStore
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave = Date.distantPast

    var records: [TemperatureHistoryRecord] { _ = revision; return recorder.records }
    var canClear: Bool { didLoad && !records.isEmpty }

    init(store: TemperatureHistoryStore = TemperatureHistoryStore()) { self.store = store }

    func load() async {
        guard !loading else { return }
        loading = true
        storageState = .loading
        let result = await store.loaded()
        loading = false
        let stored: [TemperatureHistoryRecord]
        switch result {
        case .loaded(let records):
            stored = records
            storageState = .ready
            storageDetail = ""
        case .recovered(let records, let reason):
            stored = records
            storageState = .recovered
            storageDetail = reason
        case .failed(let reason):
            storageState = .loadFailed
            storageDetail = reason
            return // Never overwrite files that could not be read.
        }
        recorder.mergeStored(stored, at: .now)
        didLoad = true
        revision &+= 1
        if dirty { persist() }
    }

    func record(_ snapshot: PowerSnapshot, rates: [String: Double]) {
        isRecording = true
        let batterySources = snapshot.batteryTemperatureReadings.map(\.id).sorted()
        let batterySource = snapshot.registryTemperature != nil ? "registry-temperature"
            : batterySources.isEmpty ? nil : "median:" + batterySources.joined(separator: "|")
        let readings: [TemperatureComponent: TemperatureObservation] = [
            .batteryTemperature: TemperatureObservation(value: snapshot.batteryTemperature, source: batterySource),
            .socTemperature: TemperatureObservation(value: snapshot.socTemperature, source: snapshot.hottestSensor(in: .soc)?.id),
            .chargerTemperature: TemperatureObservation(value: snapshot.chargerTemperature, source: snapshot.hottestSensor(in: .charger)?.id),
            .wirelessCoilTemperature: TemperatureObservation(value: snapshot.temperature(in: .wirelessCoil),
                                                            source: snapshot.hottestSensor(in: .wirelessCoil)?.id),
            .hottestTemperature: TemperatureObservation(value: snapshot.hottestSensor?.value, source: snapshot.hottestSensor?.id)
        ]
        guard recorder.observe(date: snapshot.date, readings: readings) else { return }
        latestRates = rates
        revision &+= 1
        dirty = true
        if Date.now.timeIntervalSince(lastSave) >= 30 { persist() }
    }

    func pause() {
        isRecording = false
        recorder.breakContinuity()
        latestRates = [:]
        persist()
    }

    func clear() {
        guard didLoad else { return }
        recorder.clear()
        latestRates = [:]
        revision &+= 1
        dirty = true
        persist()
    }

    func persist() {
        guard didLoad, dirty, !saving else { return }
        saving = true
        dirty = false
        lastSave = .now
        let records = recorder.records
        Task { [weak self, store] in
            let result = await store.save(records)
            guard let self else { return }
            self.saving = false
            switch result {
            case .saved:
                self.storageState = .ready
                self.storageDetail = ""
            case .backupFailed(let reason):
                self.storageState = .backupFailed
                self.storageDetail = reason
            case .failed(let reason):
                self.storageState = .saveFailed
                self.storageDetail = reason
                self.dirty = true
                return // Retry on a later checkpoint or explicit user action.
            }
            // A pause or clear may have happened during a write. Drain the newest
            // pending state even if no sensor tick will run after this completion.
            if self.dirty { self.persist() }
        }
    }

    func retry() {
        if !didLoad { Task { await load() } }
        else { dirty = true; persist() }
    }
}
