import Foundation

/// Standalone tests use production package metadata without reading installed appearance state.
nonisolated final class BrandPackageStore: @unchecked Sendable {
    static let shared = BrandPackageStore()
    var hasOverride: Bool { false }
    func current() -> BrandPackage { AppBrand.packagedPackage }
}
