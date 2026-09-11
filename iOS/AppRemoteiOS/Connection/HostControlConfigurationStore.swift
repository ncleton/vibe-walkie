import Foundation
import RemoteCore

/// A Windows or Linux host must never receive a Mac's queued shortcut update.
struct HostControlConfigurationStore {
    let defaults: UserDefaults

    struct Snapshot {
        let configuration: ControlConfiguration
        let pending: ControlConfiguration?
    }

    private func key(_ hostID: String, pending: Bool = false) -> String {
        "controlConfiguration.host.v2.\(hostID)\(pending ? ".pending" : "")"
    }

    func load(hostID: String?) throws -> Snapshot {
        guard let hostID else { return Snapshot(configuration: .standard, pending: nil) }
        let configuration = try defaults.data(forKey: key(hostID)).map {
            try RemoteCoding.decoder.decode(ControlConfiguration.self, from: $0)
        } ?? .standard
        let pending = try defaults.data(forKey: key(hostID, pending: true)).map {
            try RemoteCoding.decoder.decode(ControlConfiguration.self, from: $0)
        }
        return Snapshot(configuration: configuration, pending: pending)
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
        if defaults.data(forKey: key(selectedHostID)) == nil,
           let data = defaults.data(forKey: legacy) {
            let configuration = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: data)
            try save(configuration, hostID: selectedHostID, pending: false)
            if let pendingData = defaults.data(forKey: pending) {
                _ = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: pendingData)
                defaults.set(pendingData, forKey: key(selectedHostID, pending: true))
            }
        }
        defaults.removeObject(forKey: legacy)
        defaults.removeObject(forKey: pending)
    }
}
