import RemoteCore
import SwiftUI

extension Color {
    static let healthCoral = Color(red: 1, green: 0.23, blue: 0.34)
}

/// Compteur animé, sobre et très lisible. L'animation donne un retour de
/// progression sans modifier la valeur ni sa méthode de calcul.
struct AnimatedLongevityValue: View, @MainActor Animatable {
    var years: Double

    var animatableData: Double {
        get { years }
        set { years = newValue }
    }

    var body: some View {
        Text("≈ +\(formattedYears) ans")
            .font(.system(size: 46, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.white)
    }

    private var formattedYears: String {
        max(0, years).formatted(
            .number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(1))
        )
    }
}

/// Anneau de semaine active inspiré des indicateurs d'activité : la progression
/// est lisible, le cœur reste médical et la pulsation demeure très discrète.
struct LongevityCelebrationEmblem: View {
    let progress: Double
    let activeDayCount: Int
    let haloPhase: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.healthCoral.opacity(haloPhase ? 0.02 : 0.14), lineWidth: 2)
                    .scaleEffect(haloPhase ? 1.12 : 1)

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 7)

                Circle()
                    .trim(from: 0, to: min(max(progress, 0.015), 1))
                    .stroke(
                        Color.healthCoral,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Image(systemName: "heart.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Color.healthCoral)
                    .scaleEffect(0.84 + min(max(progress, 0), 1) * 0.16)
            }
            .frame(width: 70, height: 70)

            Text("\(activeDayCount)/7 JOURS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }
}

/// Fiche méthodologique séparée du dashboard pour garder le résultat principal
/// léger tout en rendant la provenance et les limites du chiffre vérifiables.
struct LongevityEvidenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let snapshot: HealthActivitySnapshotPayload?
    let result: EvidenceBasedLongevityEstimate.Result?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source et méthode")
                        .font(.title2.bold())
                    Text("Pourquoi ce chiffre apparaît dans Vibe Walkie")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fermer", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.headline)
                .accessibilityLabel("Fermer")
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    evidenceSection(
                        icon: "doc.text.magnifyingglass",
                        title: "L’étude",
                        text: "Moore et al. ont regroupé six cohortes prospectives totalisant 654 827 adultes. Pour les participants âgés de 40 ans ou plus, les auteurs ont comparé l’espérance de vie selon le volume hebdomadaire d’activité physique de loisir modérée à vigoureuse. Le suivi médian était de 10 ans et 82 465 décès ont été observés."
                    )

                    evidenceSection(
                        icon: "function",
                        title: "Le calcul dans Vibe Walkie",
                        text: calculationText
                    )

                    evidenceSection(
                        icon: "heart.text.square.fill",
                        title: "La mesure d’intensité",
                        text: "L’iPhone enregistre les périodes où Vibe Walkie est active et connectée au Mac. Il les croise avec les minutes d’exercice Apple Santé, que HealthKit définit comme des minutes atteignant au moins l’intensité d’une marche soutenue. Aucun échantillon Santé brut n’est envoyé : seuls les agrégats de minutes soutenues, distance et durée reviennent au Mac."
                    )

                    evidenceSection(
                        icon: "exclamationmark.shield",
                        title: "Ce que le chiffre ne dit pas",
                        text: "Cette association compare des groupes de population à l’absence d’activité de loisir modérée à vigoureuse et suppose que le rythme hebdomadaire est maintenu. L’étude est observationnelle et l’activité était déclarée par les participants : le résultat ne prouve pas une causalité et ne prédit pas la longévité d’une personne. Le palier maximal reste 4,5 ans, quelle que soit la durée au-delà de 450 minutes."
                    )

                    Link(destination: EvidenceBasedLongevityEstimate.sourceURL) {
                        Label("Lire l’étude originale dans PLOS Medicine", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.healthCoral)

                    Text("Moore SC et al. PLOS Medicine, 2012 · doi:10.1371/journal.pmed.1001335")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(22)
            }
        }
        .frame(width: 560, height: 650)
        .background(Color.remoteBackground)
        .preferredColorScheme(.dark)
    }

    private func evidenceSection(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.healthCoral)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var calculationText: String {
        guard let snapshot else {
            return "Aucun résumé Apple Santé récent n’a encore été reçu. Vibe Walkie n’affiche donc aucune estimation : ouvrez l’app sur l’iPhone pour synchroniser les sept derniers jours."
        }
        guard let briskMinutes = snapshot.briskWalkingMinutesLast7Days,
              let result else {
            return "Apple Santé ne fournit pas de minutes d’exercice exploitables pour ces sessions. Vibe Walkie n’utilise ni la durée de session seule ni un ratio de remplacement, et n’affiche donc aucune estimation."
        }
        let distance = (snapshot.walkingDistanceMetersLast7Days / 1_000).formatted(
            .number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(1))
        )
        let duration = formattedDuration(snapshot.detectedWalkingDurationLast7Days)
        return "Sur \(duration) de sessions Vibe Walkie et \(distance) km enregistrés, Apple Santé a qualifié \(Int(briskMinutes.rounded())) min au niveau d’une marche soutenue. Cette valeur est placée dans l’un des cinq paliers publiés, sans ratio ni interpolation : \(formattedYears(result.associatedYears)) ans associés après 40 ans\(confidenceText)."
    }

    private var confidenceText: String {
        guard let interval = result?.confidenceInterval else { return "" }
        return " (IC 95 % : \(formattedYears(interval.lowerBound))–\(formattedYears(interval.upperBound)) ans)"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int((duration / 60).rounded()))
        return "\(minutes / 60) h \(minutes % 60)"
    }

    private func formattedYears(_ years: Double) -> String {
        years.formatted(
            .number.locale(Locale(identifier: "fr_FR")).precision(.fractionLength(1))
        )
    }
}
