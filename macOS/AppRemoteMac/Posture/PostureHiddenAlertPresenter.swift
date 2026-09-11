import AppKit
import SwiftUI

@MainActor
final class PostureHiddenAlertPresenter {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(message: String, severity: PostureSeverity) {
        hideTask?.cancel()

        let content = PostureHiddenAlertView(message: message, severity: severity)
        let size = NSSize(width: 330, height: 92)
        let panel = panel ?? makePanel(size: size)
        panel.contentView = NSHostingView(rootView: content)
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 24,
            y: visibleFrame.minY + 24
        ))
    }
}

private struct PostureHiddenAlertView: View {
    let message: String
    let severity: PostureSeverity

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: severity == .correction
                ? "exclamationmark.triangle.fill"
                : "exclamationmark.circle.fill")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mauvaise posture détectée")
                    .font(.headline)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.9), lineWidth: severity == .correction ? 4 : 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var tint: Color {
        severity == .correction ? .red : .orange
    }
}
