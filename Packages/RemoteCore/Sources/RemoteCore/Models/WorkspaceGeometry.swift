import Foundation
import CoreGraphics

/// Layout in the view's safe area, never in physical screen coordinates.
/// The caller supplies Apple's active folding region when using the Duo SDK.
public struct WorkspaceGeometry: Equatable, Sendable {
    public let screen: CGRect
    public let controls: CGRect
    public let isExpanded: Bool

    public init(size: CGSize, regularWidth: Bool, division: CGRect? = nil) {
        let bounds = CGRect(origin: .zero, size: CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        ))
        guard regularWidth, bounds.width >= 600, bounds.height >= 240 else {
            screen = .zero
            controls = bounds
            isExpanded = false
            return
        }
        isExpanded = true
        // A horizontal fold can remain horizontal when opening the keyboard
        // changes the aspect ratio. The actual reserved region takes priority.
        if let division, !division.isNull,
           division.intersects(bounds), division.width >= bounds.width * 0.8 {
            let fold = division.intersection(bounds)
            screen = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, fold.minY - 8))
            controls = CGRect(x: 0, y: fold.maxY + 8, width: bounds.width,
                              height: max(0, bounds.height - fold.maxY - 8))
        } else if let division, !division.isNull,
                  division.intersects(bounds), division.height >= bounds.height * 0.8 {
            let fold = division.intersection(bounds)
            screen = CGRect(x: 0, y: 0, width: max(0, fold.minX - 8), height: bounds.height)
            controls = CGRect(x: fold.maxX + 8, y: 0,
                              width: max(0, bounds.width - fold.maxX - 8), height: bounds.height)
        } else if bounds.width >= bounds.height {
            let half = max(0, (bounds.width - 16) / 2)
            screen = CGRect(x: 0, y: 0, width: half, height: bounds.height)
            controls = CGRect(x: half + 16, y: 0, width: half, height: bounds.height)
        } else {
            let half = max(0, (bounds.height - 16) / 2)
            screen = CGRect(x: 0, y: 0, width: bounds.width, height: half)
            controls = CGRect(x: 0, y: half + 16, width: bounds.width, height: half)
        }
    }
}
