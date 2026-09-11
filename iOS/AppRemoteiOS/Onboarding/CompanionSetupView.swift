import SwiftUI
import RemoteCore

struct CompanionSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var platform: HostPlatform = .macOS

    var body: some View {
        NavigationStack {
            Form {
                Section("ios.companion.computer") {
                    Picker("ios.companion.system", selection: $platform) {
                        Text("Mac").tag(HostPlatform.macOS)
                        Text("Windows").tag(HostPlatform.windows)
                        Text("Linux / VPS").tag(HostPlatform.linux)
                    }
                    .pickerStyle(.segmented)
                    Text(LocalizedStringKey(instructionsKey))
                        .font(.callout)
                    Link("ios.companion.download", destination: downloadURL)
                    if platform != .macOS {
                        Link("ios.companion.installation.guide", destination: guideURL)
                    }
                }

                Section("ios.companion.pairing") {
                    if platform == .macOS {
                        Text("ios.companion.mac.pairing")
                    } else {
                        Text("ios.companion.cli.pairing")
                        Text(verbatim: "vibewalkie pair --qr pairing.png")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Text("ios.companion.cli.approval")
                    }
                    Text("ios.companion.iphone.pairing")
                }

                Section("ios.remote.mode.6c2b26c") {
                    Text("ios.companion.remote.instructions")
                    Link("ios.download.tailscale.ae8b630", destination: URL(string: "https://tailscale.com/download/ios")!)
                }
            }
            .navigationTitle("ios.companion.install")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ios.close.711e5f2") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var instructionsKey: String {
        switch platform {
        case .macOS: "ios.companion.mac.instructions"
        case .windows: "ios.companion.windows.instructions"
        case .linux: "ios.companion.linux.instructions"
        }
    }

    private var downloadURL: URL {
        platform == .macOS
            ? URL(string: "https://vibewalkie.app/download")!
            : URL(string: "https://github.com/ncleton/vibe-walkie/releases/download/companions-v1.0.0/VibeWalkie-Companions-1.0.0.zip")!
    }

    private var guideURL: URL {
        URL(string: "https://github.com/ncleton/vibe-walkie/blob/main/Companion/README.md#install-on-\(platform == .windows ? "windows" : "linux")")!
    }
}
