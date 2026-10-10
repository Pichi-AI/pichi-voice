import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Run only through scripts/dev/prepare-brand-distribution.sh, never linked into the app.
@main
struct BrandDistributionTool {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw BrandProfile.ValidationError.invalid("Usage: prepare-brand-distribution.sh BRAND.json BUNDLE_IDENTIFIER OUTPUT_DIRECTORY")
        }
        let input = URL(fileURLWithPath: arguments[1])
        guard let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= BrandPackage.maximumBytes else {
            throw BrandProfile.ValidationError.invalid("Brand package is larger than 17 MB.")
        }
        let package = try BrandPackage.decode(Data(contentsOf: input))
        let identifier = arguments[2]
        guard identifier.range(of: "^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9-]*){2,}$", options: .regularExpression) != nil,
              identifier.count <= 200, !identifier.hasSuffix(".debug") else {
            throw BrandProfile.ValidationError.invalid("Provide a unique release reverse-DNS bundle identifier with at least three components.")
        }
        guard !package.profile.appName.contains("//"), !package.profile.appName.contains("/*"),
              package.profile.appName.rangeOfCharacter(from: CharacterSet(charactersIn: "$\"\\\n\r=#:;/")) == nil else {
            throw BrandProfile.ValidationError.invalid("The product name cannot contain build-setting or path syntax.")
        }
        guard let logo = package.logos?.primary else {
            throw BrandProfile.ValidationError.invalid("A separate distribution requires an embedded primary logo.")
        }
        let imageData = try logo.validatedData()
        let source = CGImageSourceCreateWithData(imageData as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let destination = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw BrandProfile.ValidationError.invalid("Choose a new output directory; existing files are never overwritten.")
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".brand-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let resources = staging.appendingPathComponent("Sources/Fluid/Branding", isDirectory: true)
        let icons = staging.appendingPathComponent("Sources/Fluid/Assets.xcassets/BrandAppIcon.appiconset", isDirectory: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        try files.createDirectory(at: icons, withIntermediateDirectories: true)
        try package.encoded().write(to: resources.appendingPathComponent("brand-package.json"), options: .atomic)
        var distribution = BrandDistribution(formatVersion: 1, appIconAsset: "BrandAppIcon")
        if let repository = package.links?.repository, URL(string: repository)?.host == "github.com" { distribution.repository = repository }
        try distribution.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(distribution).write(to: resources.appendingPathComponent("brand-distribution.json"), options: .atomic)
        var entries: [[String: String]] = []
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let filename = "icon-\(size)@\(scale)x.png"
                try self.png(image: image, size: size * scale).write(to: icons.appendingPathComponent(filename))
                entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
            }
        }
        let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: icons.appendingPathComponent("Contents.json"))
        let settings = "// Generated visual identity. Signing, analytics and updater policy are separate.\nPICHI_PRODUCT_NAME = \(package.profile.appName)\nPICHI_BUNDLE_IDENTIFIER = \(identifier)\nPICHI_APP_ICON = BrandAppIcon\n"
        try Data(settings.utf8).write(to: staging.appendingPathComponent("Brand.xcconfig"))
        try files.moveItem(at: staging, to: destination)
        print("Prepared brand resources, 10 icon sizes and Brand.xcconfig at \(destination.path)")
        print("Copy the generated Sources subtree into an isolated distribution worktree, then pass -xcconfig Brand.xcconfig to Xcode. Configure signing separately.")
    }

    private static func png(image: CGImage, size: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BrandProfile.ValidationError.invalid("Could not create distribution icon.")
        }
        let factor = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * factor
        let height = CGFloat(image.height) * factor
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height))
        let data = NSMutableData()
        guard let bitmap = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BrandProfile.ValidationError.invalid("Could not encode distribution icon.")
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw BrandProfile.ValidationError.invalid("Could not encode distribution icon.") }
        return data as Data
    }
}
