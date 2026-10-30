import SwiftUI

/// A presentation request belongs to the stable Form, because Section distributes
/// modifiers across its rows and cannot own one shared editor presentation.
struct MobileSensitiveDictionaryEdit: Identifiable {
    let id = UUID()
    let entry: SensitiveDataDictionaryEntry?
}

/// Entries remain in the existing local Settings namespace. Publication uses the shared
/// privacy adapter, never a view-only replacement of transcript text.
struct MobileSensitiveDictionarySettings: View {
    let edit: (SensitiveDataDictionaryEntry?) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(settings.sensitiveDataDictionaryEntries) { entry in
                Button { edit(entry) } label: {
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
            Button { edit(nil) } label: {
                Label(PichiLocalization.text("Add word or phrase"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .foregroundStyle(theme.palette.accentText)
            }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.add")
            if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning) }
        } header: {
            Text(PichiLocalization.text("Words and phrases to hide"))
        } footer: {
            MobileSettingsFooter(PichiLocalization.text("Add names, words or phrases that should also be hidden when data cleanup is enabled. The dictionary stays on this device and applies to new recordings."))
        }
    }
}

struct MobileSensitiveDictionaryEditor: View {
    let entry: SensitiveDataDictionaryEntry?
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: String
    @State private var error: String?

    init(entry: SensitiveDataDictionaryEntry?) {
        self.entry = entry
        _phrase = State(initialValue: entry?.phrase ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(PichiLocalization.text("Word or phrase"), text: $phrase, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("privacy.dictionary.phrase")
                Text(PichiLocalization.text("Whole words and phrases are matched without case sensitivity. Parts of other words are kept."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                if let error { Text(error).foregroundStyle(theme.palette.warning) }
                if let entry {
                    Button(role: .destructive) {
                        do { try settings.removeSensitiveDataDictionaryPhrase(id: entry.id); dismiss() }
                        catch { self.error = PichiLocalization.text("Could not update the private dictionary.") }
                    } label: {
                        Text(PichiLocalization.text("Delete"))
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.delete")
                }
            }.navigationTitle(PichiLocalization.text(entry == nil ? "Add word or phrase" : "Edit word or phrase"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Text(PichiLocalization.text("Cancel")).font(theme.typography.body)
                                .fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: {
                            Text(PichiLocalization.text("Save")).font(theme.typography.body)
                                .fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain)
                            .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("privacy.dictionary.save")
                    }
                }
        }.presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            if let entry { try settings.updateSensitiveDataDictionaryPhrase(id: entry.id, phrase: phrase) }
            else { try settings.addSensitiveDataDictionaryPhrase(phrase) }
            dismiss()
        } catch {
            // No private phrase is copied into errors or logs.
            self.error = PichiLocalization.text("Use a unique phrase of up to 16 words and 256 characters. The dictionary can contain up to 128 entries.")
        }
    }
}
