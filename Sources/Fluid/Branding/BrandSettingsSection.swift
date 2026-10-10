import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct BrandSettingsSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Appearance").font(self.theme.typography.bodyStrong)
                Spacer()
                Picker("Theme", selection: Binding(get: { self.settings.themePreference }, set: { self.settings.themePreference = $0 })) {
                    ForEach(SettingsStore.ThemePreference.allCases) { preference in
                        Text(PichiLocalization.text(preference.displayName)).tag(preference)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brand profile").font(self.theme.typography.bodyStrong)
                    Text(AppBrand.appName).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Button("Import JSON", action: self.importProfile).controlSize(.small)
                Button("Import logo", action: self.importLogo).controlSize(.small)
                Button("Reset", action: self.reset).controlSize(.small)
            }
            Text("Brand names, links and colors apply throughout the app. Restart to refresh window titles and menus. Installation identity and updates are configured when building the app.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if let errorMessage {
                Text(PichiLocalization.text(errorMessage)).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= 32_768 else {
                throw BrandProfile.ValidationError.invalid("Profile is larger than 32 KB.")
            }
            let data = try Data(contentsOf: url)
            let profile = try BrandProfile.decode(data)
            UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: AppBrand.profileDefaultsKey)
            self.settings.accentColorOption = .brand
            NotificationCenter.default.post(name: AppBrand.appearanceChanged, object: nil)
            self.errorMessage = nil
        } catch { self.errorMessage = error.localizedDescription }
    }

    private func importLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= 4_194_304 else {
                throw BrandProfile.ValidationError.invalid("Logo must be no larger than 4 MB.")
            }
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
                  image.size.width <= 4096, image.size.height <= 4096
            else { throw BrandProfile.ValidationError.invalid("Choose a valid PNG or JPEG logo up to 4096 pixels per side.") }
            UserDefaults.standard.set(data, forKey: "PichiBrandLogo")
            PichiBrandMark.customImage = image
            NSApplication.shared.applicationIconImage = image
            self.settings.objectWillChange.send()
            NotificationCenter.default.post(name: AppBrand.appearanceChanged, object: nil)
            self.errorMessage = nil
        } catch { self.errorMessage = error.localizedDescription }
    }

    private func reset() {
        UserDefaults.standard.removeObject(forKey: AppBrand.profileDefaultsKey)
        UserDefaults.standard.removeObject(forKey: "PichiBrandLogo")
        PichiBrandMark.customImage = nil
        NSApplication.shared.applicationIconImage = PichiBrandMark.packagedIcon
        self.settings.accentColorOption = .brand
        NotificationCenter.default.post(name: AppBrand.appearanceChanged, object: nil)
        self.errorMessage = nil
    }
}
