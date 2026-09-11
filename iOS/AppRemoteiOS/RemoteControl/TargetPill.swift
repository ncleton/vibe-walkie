import SwiftUI
import RemoteCore

/// Pilule supérieure : Mac, application active, accès au sélecteur.
struct TargetPill: View {
    @EnvironmentObject private var client: HostConnectionClient
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.remoteBlue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(!client.state.isReady)
        .accessibilityLabel(AppL10n.format("ios.target.app.value.f90e281", title))
    }

    private var activeApplication: RemoteApplication? {
        guard let snapshot = client.snapshot else { return nil }
        return snapshot.applications.first { $0.id == snapshot.activeApplicationID }
    }

    @ViewBuilder
    private var icon: some View {
        if let data = activeApplication?.iconPNG, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: client.state.isReady ? "desktopcomputer" : "wifi.slash")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var title: String {
        switch client.state {
        case .ready:
            return activeApplication?.name ?? client.state.hostName ?? "Vibe Walkie"
        case .connecting(let name):
            return name
        case .pairing(let name, _):
            return name
        case .awaitingApproval(let name, _):
            return name
        case .searching:
            return AppL10n.text("ios.searching.for.mac.2f5c79e")
        case .failed(let code):
            return AppL10n.remoteError(code)
        case .idle:
            return AppL10n.text("ios.no.mac.1bc46bc")
        }
    }

    private var subtitle: String? {
        guard client.state.isReady else { return nil }
        guard let app = activeApplication else { return client.state.hostName }
        let applicationDetail = app.windows.first?.title
        return [client.state.hostName, applicationDetail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Bouton circulaire des coins, façon Télécommande Apple.
struct CircularControlButton: View {
    let systemImage: String
    var size: CGFloat = 52
    var iconSize: CGFloat = 18
    var isProminent: Bool = false
    var accessibilityText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isProminent ? Color.remoteBlue : Color.controlSurface)
                .frame(width: size, height: size)
                .overlay(
                    Circle().stroke(Color.white.opacity(isProminent ? 0.12 : 0.06), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(isProminent ? .white : Color.remoteBlue)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }
}
