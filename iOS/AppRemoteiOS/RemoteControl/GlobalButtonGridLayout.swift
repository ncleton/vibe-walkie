import RemoteCore

/// Disposition locale de la palette Global. Les cases vides restent sur
/// l'iPhone afin de ne pas modifier le protocole partagé avec les compagnons.
enum GlobalButtonGridLayout {
    static let columnCount = 4
    static let minimumSlotCount = 12
    static let maximumSlotCount = 36

    static func resolvedSlots(
        storedIDs: [String?],
        availableButtons: [GlobalButtonConfiguration]
    ) -> [GlobalButtonConfiguration?] {
        let buttonsByID = Dictionary(uniqueKeysWithValues: availableButtons.map { ($0.id, $0) })
        var seen = Set<String>()
        var slotIDs = storedIDs.prefix(maximumSlotCount).map { id -> String? in
            guard let id,
                  buttonsByID[id] != nil,
                  seen.insert(id).inserted else {
                return nil
            }
            return id
        }

        for button in availableButtons where seen.insert(button.id).inserted {
            if let emptyIndex = slotIDs.firstIndex(where: { $0 == nil }) {
                slotIDs[emptyIndex] = button.id
            } else if slotIDs.count < maximumSlotCount {
                slotIDs.append(button.id)
            }
        }

        while !slotIDs.isEmpty, slotIDs[slotIDs.count - 1] == nil {
            slotIDs.removeLast()
        }

        let countWithDropTarget = min(maximumSlotCount, slotIDs.count + 1)
        let roundedCount = ((countWithDropTarget + columnCount - 1) / columnCount) * columnCount
        let targetCount = min(maximumSlotCount, max(minimumSlotCount, roundedCount))
        slotIDs.append(contentsOf: repeatElement(nil, count: max(0, targetCount - slotIDs.count)))

        return slotIDs.map { id in
            id.flatMap { buttonsByID[$0] }
        }
    }

    static func storageIDs(from slots: [GlobalButtonConfiguration?]) -> [String?] {
        var seen = Set<String>()
        var ids = slots.prefix(maximumSlotCount).map { button -> String? in
            guard let id = button?.id, seen.insert(id).inserted else { return nil }
            return id
        }
        while !ids.isEmpty, ids[ids.count - 1] == nil {
            ids.removeLast()
        }
        return ids
    }
}
