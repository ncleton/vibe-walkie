import Foundation
import RemoteCore

/// A Windows or Linux host must never receive a Mac's queued shortcut update.
struct HostControlConfigurationStore {
    let defaults: UserDefaults

    struct Snapshot {
        let configuration: ControlConfiguration
        let pending: ControlConfiguration?
        let slotIDs: [String?]
    }

    private func key(_ hostID: String, pending: Bool = false) -> String {
        "controlConfiguration.host.v2.\(hostID)\(pending ? ".pending" : "")"
    }

    func load(hostID: String?) throws -> Snapshot {
        guard let hostID else { return Snapshot(configuration: .standard, pending: nil, slotIDs: []) }
        let configuration = try defaults.data(forKey: key(hostID)).map {
            try RemoteCoding.decoder.decode(ControlConfiguration.self, from: $0)
        } ?? .standard
        let pending = try defaults.data(forKey: key(hostID, pending: true)).map {
            try RemoteCoding.decoder.decode(ControlConfiguration.self, from: $0)
        }
        let slotIDs = try defaults.data(forKey: key(hostID) + ".slots").map {
            try JSONDecoder().decode([String?].self, from: $0)
        } ?? []
        return Snapshot(configuration: configuration, pending: pending, slotIDs: slotIDs)
    }

    func saveSlots(_ ids: [String?], hostID: String) throws {
        defaults.set(try JSONEncoder().encode(ids), forKey: key(hostID) + ".slots")
    }

    func save(_ configuration: ControlConfiguration, hostID: String, pending: Bool) throws {
        let data = try RemoteCoding.encoder.encode(configuration)
        defaults.set(data, forKey: key(hostID))
        if pending {
            defaults.set(data, forKey: key(hostID, pending: true))
        } else {
            defaults.removeObject(forKey: key(hostID, pending: true))
        }
    }

    func migrateLegacy(selectedHostID: String?) throws {
        guard let selectedHostID else { return }
        let legacy = "controlConfiguration.v1"
        let pending = "controlConfiguration.pending.v1"
        let slots = "globalButtonSlotIDs.v1"
        let slotData = defaults.data(forKey: slots)
        if let slotData { _ = try JSONDecoder().decode([String?].self, from: slotData) }
        if defaults.data(forKey: key(selectedHostID)) == nil,
           let data = defaults.data(forKey: legacy) {
            let configuration = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: data)
            let pendingData = defaults.data(forKey: pending)
            // Validate the complete migration before changing either host key.
            if let pendingData {
                _ = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: pendingData)
            }
            try save(configuration, hostID: selectedHostID, pending: false)
            if let pendingData {
                defaults.set(pendingData, forKey: key(selectedHostID, pending: true))
            }
        }
        if defaults.data(forKey: key(selectedHostID) + ".slots") == nil, let slotData {
            defaults.set(slotData, forKey: key(selectedHostID) + ".slots")
        }
        defaults.removeObject(forKey: legacy)
        defaults.removeObject(forKey: pending)
        defaults.removeObject(forKey: slots)
    }
}
