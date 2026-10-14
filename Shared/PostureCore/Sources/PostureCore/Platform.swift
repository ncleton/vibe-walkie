import Foundation
#if os(Windows)
struct CGPoint: Equatable, Sendable {
    var x: Double; var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
}
struct CGSize: Equatable, Sendable { var width: Double; var height: Double }
#endif
#if !canImport(simd)
func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
func simd_length(_ a: SIMD3<Float>) -> Float { sqrt(simd_dot(a, a)) }
#endif
