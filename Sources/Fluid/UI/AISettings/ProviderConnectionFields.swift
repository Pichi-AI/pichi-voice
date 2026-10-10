import SwiftUI

/// Both the unsaved draft and saved provider editor use the same metadata fields.
struct ProviderConnectionFields: View {
    @Environment(\.theme) private var theme
    let provider: CloudTextProvider
    @Binding var options: [String: String]

    var body: some View {
        ForEach(self.provider.fields) { field in
            VStack(alignment: .leading, spacing: 6) {
                Text(PichiLocalization.text(field.title)).font(self.theme.typography.bodyStrong)
                let binding = Binding(get: { self.options[field.id] ?? field.defaultValue }, set: { self.options[field.id] = $0 })
                if field.choices.isEmpty {
                    TextField(PichiLocalization.text(field.title), text: binding)
                        .textFieldStyle(.roundedBorder)
                        .font(self.theme.typography.body)
                        .accessibilityLabel(PichiLocalization.text(field.title))
                } else {
                    Picker(PichiLocalization.text(field.title), selection: binding) {
                        ForEach(field.choices, id: \.self) { choice in Text(verbatim: choice).tag(choice) }
                    }.labelsHidden()
                }
            }
        }
    }
}
