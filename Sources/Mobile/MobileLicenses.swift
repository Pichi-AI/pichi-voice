import SwiftUI

struct MobileLicensesSettings: View {
    private let catalog = try? MobileLicensesCatalog.load()
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            if let catalog {
                ForEach(catalog.groups) { group in
                    Section {
                        ForEach(group.components) { component in
                            NavigationLink {
                                MobileLicenseDetail(component: component)
                            } label: {
                                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                                    Text(verbatim: component.name).font(theme.typography.body)
                                        .foregroundStyle(theme.palette.primaryText)
                                    Text(verbatim: component.license).font(theme.typography.caption)
                                        .foregroundStyle(theme.palette.secondaryText)
                                }
                                .padding(.vertical, theme.metrics.spacing.xs)
                            }
                            .accessibilityIdentifier("licenses.component.\(component.id)")
                        }
                    } header: {
                        Text(PichiLocalization.text(group.titleKey))
                    } footer: {
                        if let footerKey = group.footerKey {
                            MobileSettingsFooter(PichiLocalization.text(footerKey))
                        }
                    }
                }
            } else {
                Text(PichiLocalization.text("Licenses could not be loaded."))
                    .foregroundStyle(theme.palette.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .mobileSettingsPage()
        .navigationTitle(PichiLocalization.text("Licenses"))
        .accessibilityIdentifier("settings.licenses.detail")
    }
}

private struct MobileLicenseDetail: View {
    let component: MobileLicensesCatalog.Component
    private let documents: [(document: MobileLicensesCatalog.Document, text: String)]?
    @Environment(\.theme) private var theme

    init(component: MobileLicensesCatalog.Component) {
        self.component = component
        self.documents = try? component.documents.map { ($0, try MobileLicensesCatalog.text(for: $0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.lg) {
                Text(verbatim: component.license)
                    .font(theme.typography.bodyStrong).foregroundStyle(theme.palette.secondaryText)
                if let documents {
                    ForEach(documents, id: \.document.id) { item in
                        VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
                            Text(PichiLocalization.text(item.document.titleKey)).font(theme.typography.bodyStrong)
                            Text(verbatim: item.text).font(theme.typography.bodySmall)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("licenses.document.\(item.document.file)")
                        }
                    }
                } else {
                    Text(PichiLocalization.text("Licenses could not be loaded."))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
            .foregroundStyle(theme.palette.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.metrics.spacing.lg)
        }
        .mobileReadableColumn()
        .background(theme.palette.contentBackground)
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("licenses.component.detail")
    }
}
