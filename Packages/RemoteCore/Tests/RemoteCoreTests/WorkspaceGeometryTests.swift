import Foundation
import Testing
@testable import RemoteCore

@Suite("Workspace resizing and fold avoidance")
struct WorkspaceGeometryTests {
    @Test("Compact displays preserve the entire remote control", arguments: [
        CGSize(width: 320, height: 520), CGSize(width: 430, height: 680), CGSize(width: 640, height: 320)
    ])
    func compact(size: CGSize) {
        let layout = WorkspaceGeometry(size: size, regularWidth: false)
        #expect(!layout.isExpanded)
        #expect(layout.screen == .zero)
        #expect(layout.controls.size == size)
    }

    @Test("Open workspace allocates half to the screen and half to controls", arguments: [
        CGSize(width: 800, height: 650), CGSize(width: 650, height: 900)
    ])
    func expanded(size: CGSize) {
        let layout = WorkspaceGeometry(size: size, regularWidth: true)
        #expect(layout.isExpanded)
        #expect(layout.controls.size == layout.screen.size)
        #expect(!layout.controls.intersects(layout.screen))
        #expect(CGRect(origin: .zero, size: size).contains(layout.controls))
    }

    @Test("Both panels avoid the actual hinge, including an off-center fold", arguments: [
        CGRect(x: 340, y: 0, width: 28, height: 650), CGRect(x: 0, y: 270, width: 800, height: 24)
    ])
    func hinge(region: CGRect) {
        let layout = WorkspaceGeometry(size: CGSize(width: 800, height: 650), regularWidth: true, division: region)
        #expect(!layout.screen.intersects(region))
        #expect(!layout.controls.intersects(region))
        #expect(layout.screen.width > 0 && layout.screen.height > 0)
        #expect(layout.controls.width > 0 && layout.controls.height > 0)
    }

    @Test("Split View can collapse a regular size class into a usable compact remote")
    func multitasking() {
        let layout = WorkspaceGeometry(size: CGSize(width: 420, height: 700), regularWidth: true)
        #expect(!layout.isExpanded)
    }
}
