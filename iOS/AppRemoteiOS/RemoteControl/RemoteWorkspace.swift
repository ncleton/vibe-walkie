import SwiftUI
import RemoteCore

@MainActor
enum RemoteScreenIdlePolicy {
    private static var owners = Set<UUID>()

    static func setActive(_ active: Bool, owner: UUID) {
        if active { owners.insert(owner) } else { owners.remove(owner) }
        UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
    }
}

/// Both children retain their identity across fold, resize and keyboard changes.
struct RemoteWorkspaceLayout: Layout {
    let geometry: WorkspaceGeometry

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, [geometry.screen, geometry.controls]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

enum RemoteWorkspaceRegions {
    static func division(in proxy: GeometryProxy) -> CGRect? {
        // Enabled by scripts/build-duo.sh only after verifying iOS SDK >= 27.1.
        // Older iOS builds support resizing; they cannot certify hinge avoidance.
#if VIBE_WALKIE_DUO_SDK
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first?.frame
        }
#endif
        return nil
    }
}

/// Live feedback shared by the expanded workspace. No synthetic frame is used.
struct RemoteWorkspaceScreen: View {
    @EnvironmentObject private var client: HostConnectionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var streamOwner = UUID()
    let enabled: Bool
    let expand: () -> Void

    private var active: Bool {
        enabled && scenePhase == .active && client.state.isReady && client.supports(.screenStreaming)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(client.selectedHost?.name ?? "Vibe Walkie", systemImage: "display")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button(action: expand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("ios.screen.view.b5645a8")
            }
            ZStack {
                Color.black
                if !client.state.isReady {
                    ContentUnavailableView("ios.workspace.disconnected", systemImage: "network.slash")
                } else if !client.supports(.screenStreaming) {
                    ContentUnavailableView("ios.workspace.screen.unavailable", systemImage: "display.trianglebadge.exclamationmark")
                } else if let frame = client.latestScreenFrame, let image = UIImage(data: frame.jpegData) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .accessibilityLabel("ios.workspace.live.screen")
                } else if let detail = client.screenStreamStatus.detail {
                    ContentUnavailableView {
                        Label("ios.workspace.screen.unavailable", systemImage: "display.trianglebadge.exclamationmark")
                    } description: { Text(detail) }
                } else {
                    ProgressView("ios.workspace.screen.connecting").tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .task(id: active) {
            guard active else { return }
            let requestedAt = Date()
            client.startScreenStream(owner: streamOwner)
            // A stale image must never be presented as current remote feedback.
            while !Task.isCancelled && active {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard !Task.isCancelled, active else { break }
                if Date().timeIntervalSince(client.lastScreenFrameAt ?? requestedAt) > 8 {
                    client.reportStaleScreenStream(owner: streamOwner)
                    break
                }
            }
        }
        .onChange(of: active) { old, new in
            if old && !new { client.stopScreenStream(owner: streamOwner) }
        }
        .onChange(of: active, initial: true) { _, new in
            RemoteScreenIdlePolicy.setActive(new, owner: streamOwner)
        }
        .onDisappear {
            RemoteScreenIdlePolicy.setActive(false, owner: streamOwner)
            if enabled { client.stopScreenStream(owner: streamOwner) }
        }
    }
}
