import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct BrandSettingsSection: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var errorMessage: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Appearance").font(self.theme.typography.bodyStrong)
                Spacer()
                Picker("Theme", selection: Binding(get: { self.settings.themePreference }, set: { self.settings.themePreference = $0 })) {
                    ForEach(SettingsStore.ThemePreference.allCases) { preference in
                        // Let the native Text resolve its trusted UI key on every inherited locale change.
                        Text(LocalizedStringKey(preference.displayName)).tag(preference)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PichiLocalization.text("Brand package")).font(self.theme.typography.bodyStrong)
                    Text(AppBrand.appName).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                if self.importing { ProgressView().controlSize(.small) }
                Button(PichiLocalization.text("Import brand"), action: self.importPackage).controlSize(.small)
                Button(PichiLocalization.text("Export brand"), action: self.exportPackage).controlSize(.small)
                Button("Import logo", action: self.importLogo).controlSize(.small)
                Button("Reset", action: self.reset).controlSize(.small)
            }
            .disabled(self.importing)
            Text(PichiLocalization.text("One JSON file contains names, logos, light and dark palettes, style and links. Import applies them immediately. Installation identity and network policy belong to the signed distribution."))
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(PichiLocalization.text(errorMessage)).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.performImport {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= BrandPackage.maximumBytes else {
                throw BrandProfile.ValidationError.invalid("Brand package is larger than 17 MB.")
            }
            return try Data(contentsOf: url)
        }
    }

    private func importLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.performImport {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= BrandLogo.maximumBytes else {
                throw BrandProfile.ValidationError.invalid("Logo must be no larger than 4 MB.")
            }
            let logo = try BrandLogo(data: Data(contentsOf: url))
            var package = BrandPackageStore.shared.current()
            package.logos = BrandLogos(primary: logo)
            return try package.encoded()
        }
    }

    private func performImport(_ read: @escaping @Sendable () throws -> Data) {
        self.importing = true
        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try BrandPackageStore.shared.importData(read())
                }.value
                self.settings.accentColorOption = .brand
                if let appearance = package.style?.defaultAppearance {
                    self.settings.themePreference = SettingsStore.ThemePreference(rawValue: appearance.rawValue) ?? .system
                }
                BrandAppearanceController.apply()
                self.errorMessage = nil
            } catch { self.errorMessage = error.localizedDescription }
            self.importing = false
        }
    }

    private func exportPackage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "brand.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BrandPackageStore.shared.exportData().write(to: url, options: .atomic)
            self.errorMessage = nil
        } catch { self.errorMessage = error.localizedDescription }
    }

    private func reset() {
        do { try BrandPackageStore.shared.reset() }
        catch { self.errorMessage = error.localizedDescription; return }
        self.settings.accentColorOption = .brand
        self.settings.themePreference = SettingsStore.ThemePreference(rawValue: AppBrand.package.style?.defaultAppearance.rawValue ?? "system") ?? .system
        BrandAppearanceController.apply()
        self.errorMessage = nil
    }
}
