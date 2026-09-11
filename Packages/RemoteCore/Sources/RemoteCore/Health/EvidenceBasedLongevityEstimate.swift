import Foundation

/// Association populationnelle publiée entre marche soutenue hebdomadaire et
/// espérance de vie après 40 ans.
///
/// Les paliers sont repris sans interpolation de Moore et al. (PLOS Medicine,
/// 2012), analyse groupée de 654 827 adultes. L'étude compare chaque niveau
/// d'activité de loisir modérée à vigoureuse à l'absence d'une telle activité.
/// Il s'agit d'une association observée, pas d'une prédiction individuelle.
public struct EvidenceBasedLongevityEstimate: Equatable, Sendable {
    public struct Result: Equatable, Sendable {
        public let associatedYears: Double
        public let confidenceInterval: ClosedRange<Double>?
        public let briskWalkingMinutesRange: Range<Double>?

        init(
            associatedYears: Double,
            confidenceInterval: ClosedRange<Double>?,
            briskWalkingMinutesRange: Range<Double>?
        ) {
            self.associatedYears = associatedYears
            self.confidenceInterval = confidenceInterval
            self.briskWalkingMinutesRange = briskWalkingMinutesRange
        }
    }

    public static let sourceTitle = "Moore et al., PLOS Medicine (2012)"
    public static let sourceURL = URL(
        string: "https://doi.org/10.1371/journal.pmed.1001335"
    )!

    /// Minutes hebdomadaires projetées au niveau d'une marche soutenue.
    /// `nil` signifie qu'aucune mesure d'intensité exploitable n'est disponible.
    public let weeklyBriskWalkingMinutes: Double?

    public init(weeklyBriskWalkingMinutes: Double?) {
        self.weeklyBriskWalkingMinutes = weeklyBriskWalkingMinutes
    }

    /// Paliers publiés, exprimés par l'article comme minutes hebdomadaires
    /// approximatives de marche soutenue (brisk walking).
    public var result: Result? {
        guard let weeklyBriskWalkingMinutes else { return nil }
        switch max(0, weeklyBriskWalkingMinutes) {
        case ...0:
            return Result(
                associatedYears: 0,
                confidenceInterval: nil,
                briskWalkingMinutesRange: nil
            )
        case ..<75:
            return Result(
                associatedYears: 1.8,
                confidenceInterval: 1.6...2.0,
                briskWalkingMinutesRange: 0..<75
            )
        case ..<150:
            return Result(
                associatedYears: 2.5,
                confidenceInterval: 2.2...2.7,
                briskWalkingMinutesRange: 75..<150
            )
        case ..<300:
            return Result(
                associatedYears: 3.4,
                confidenceInterval: 3.2...3.6,
                briskWalkingMinutesRange: 150..<300
            )
        case ..<450:
            return Result(
                associatedYears: 4.2,
                confidenceInterval: 4.0...4.5,
                briskWalkingMinutesRange: 300..<450
            )
        default:
            return Result(
                associatedYears: 4.5,
                confidenceInterval: 4.3...4.7,
                briskWalkingMinutesRange: 450..<Double.greatestFiniteMagnitude
            )
        }
    }
}
