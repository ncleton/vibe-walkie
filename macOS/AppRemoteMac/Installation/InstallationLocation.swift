import AppKit

enum InstallationLocation {
    static var isInstalledApplication: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var isSuitable: Bool {
#if DEBUG
        true
#else
        isInstalledApplication
#endif
    }

    static func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }
}
