import Foundation

@main
struct BrandProfileTests {
    static func main() throws {
        let valid = try JSONEncoder().encode(BrandProfile.pichi)
        let decoded = try BrandProfile.decode(valid)
        precondition(decoded == .pichi)
        let custom = BrandProfile(appName: "Team Voice", meetingName: "Team Meetings", assistantName: "Team AI", tagline: "Private speech", accentLight: "#123456", accentDark: "#ABCDEF", website: "https://example.com", support: "https://example.com/support")
        let decodedCustom = try BrandProfile.decode(JSONEncoder().encode(custom))
        precondition(decodedCustom == custom)
        for (key, value) in [("appName", ""), ("meetingName", "Line\nBreak"), ("assistantName", String(repeating: "x", count: 121)), ("accentLight", "#ABC"), ("accentDark", "GGGGGG"), ("website", "http://example.com"), ("support", "https://user:password@example.com")] {
            var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
            object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object)
            do { _ = try BrandProfile.decode(data); fatalError("Accepted invalid \(key)") } catch {}
        }
        do { _ = try BrandProfile.decode(Data(repeating: 32, count: 32_769)); fatalError("Accepted oversized profile") } catch {}
        precondition(AppBrand.bundleIdentifier != "com.FluidApp.app")
        precondition(AppBrand.keychainService.hasPrefix(AppBrand.bundleIdentifier))
        precondition(AppBrand.modelsDirectory.path.contains(AppBrand.bundleIdentifier))
        precondition(AppBrand.cachesDirectory.path.contains(AppBrand.bundleIdentifier))
        precondition(!AppBrand.updatesEnabled && AppBrand.feedbackEndpoint == nil)
        // A visual profile cannot change installation or network policy.
        var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        object["updatesEnabled"] = true
        object["bundleIdentifier"] = "com.FluidApp.app"
        _ = try BrandProfile.decode(JSONSerialization.data(withJSONObject: object))
        precondition(!AppBrand.updatesEnabled && AppBrand.bundleIdentifier != "com.FluidApp.app")
        print("Brand profile validation and identity isolation passed")
    }
}
