import SwiftUI

/// Entries remain in the existing local Settings namespace. Publication uses the shared
/// privacy adapter, never a view-only replacement of transcript text.
struct MobileSensitiveDictionarySettings: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var editing: SensitiveDataDictionaryEntry?
    @State private var adding = false
    @State private var phrase = ""
    @State private var error: String?

    var body: some View {
        Section(PichiLocalization.text("Words and phrases to hide")) {
            Text(PichiLocalization.text("Add names, words or phrases that should also be hidden when data cleanup is enabled. The dictionary stays on this device and applies to new meetings."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            ForEach(settings.sensitiveDataDictionaryEntries) { entry in
                Button {
                    editing = entry; phrase = entry.phrase; error = nil
                } label: {
                    HStack {
                        Text(entry.phrase).foregroundStyle(theme.palette.primaryText)
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(theme.palette.secondaryText)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.entry.\(entry.id)")
                    .swipeActions {
                        Button(PichiLocalization.text("Delete"), role: .destructive) {
                            do { try settings.removeSensitiveDataDictionaryPhrase(id: entry.id) }
                            catch { self.error = PichiLocalization.text("Could not update the private dictionary.") }
                        }
                    }
            }
            Button {
                phrase = ""; error = nil; adding = true
            } label: {
                Label(PichiLocalization.text("Add word or phrase"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .foregroundStyle(theme.palette.accentText)
            }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.add")
            if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning) }
        }
        .sheet(isPresented: Binding(get: { adding || editing != nil }, set: { if !$0 { close() } })) {
            NavigationStack {
                Form {
                    TextField(PichiLocalization.text("Word or phrase"), text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("privacy.dictionary.phrase")
                    Text(PichiLocalization.text("Whole words and phrases are matched without case sensitivity. Parts of other words are kept."))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    if let error { Text(error).foregroundStyle(theme.palette.warning) }
                    if let editing {
                        Button(role: .destructive) {
                            do { try settings.removeSensitiveDataDictionaryPhrase(id: editing.id); close() }
                            catch { self.error = PichiLocalization.text("Could not update the private dictionary.") }
                        } label: {
                            Text(PichiLocalization.text("Delete"))
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.delete")
                    }
                }.navigationTitle(PichiLocalization.text(editing == nil ? "Add word or phrase" : "Edit word or phrase"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(PichiLocalization.text("Cancel")) { close() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(PichiLocalization.text("Save")) { save() }
                                .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("privacy.dictionary.save")
                        }
                    }
            }.presentationDetents([.medium, .large])
        }
    }

    private func close() { adding = false; editing = nil; phrase = ""; error = nil }
    private func save() {
        do {
            if let editing { try settings.updateSensitiveDataDictionaryPhrase(id: editing.id, phrase: phrase) }
            else { try settings.addSensitiveDataDictionaryPhrase(phrase) }
            close()
        } catch {
            // No private phrase is copied into errors or logs.
            self.error = PichiLocalization.text("Use a unique phrase of up to 16 words and 256 characters. The dictionary can contain up to 128 entries.")
        }
    }
}
