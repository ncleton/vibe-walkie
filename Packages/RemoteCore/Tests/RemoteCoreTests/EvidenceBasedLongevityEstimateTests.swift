import Testing
@testable import RemoteCore

@Suite("Paliers d’espérance de vie publiés")
struct EvidenceBasedLongevityEstimateTests {
    @Test(
        "Chaque seuil reprend le palier Moore et al. sans interpolation",
        arguments: [
            (30.0, 1.8, 1.6, 2.0),
            (75.0, 2.5, 2.2, 2.7),
            (150.0, 3.4, 3.2, 3.6),
            (300.0, 4.2, 4.0, 4.5),
            (450.0, 4.5, 4.3, 4.7),
        ]
    )
    func publishedThresholds(item: (Double, Double, Double, Double)) throws {
        let result = try #require(
            EvidenceBasedLongevityEstimate(
                weeklyBriskWalkingMinutes: item.0
            ).result
        )

        #expect(result.associatedYears == item.1)
        #expect(result.confidenceInterval?.lowerBound == item.2)
        #expect(result.confidenceInterval?.upperBound == item.3)
    }

    @Test("Le résultat est plafonné au palier maximal publié")
    func maximumIsCapped() throws {
        let result = try #require(
            EvidenceBasedLongevityEstimate(
                weeklyBriskWalkingMinutes: 10 * 60 * 7
            ).result
        )

        #expect(result.associatedYears == 4.5)
        #expect(result.confidenceInterval == 4.3...4.7)
    }

    @Test("Une intensité indisponible ne produit pas d’estimation")
    func missingIntensity() {
        #expect(
            EvidenceBasedLongevityEstimate(
                weeklyBriskWalkingMinutes: nil
            ).result == nil
        )
    }
}
