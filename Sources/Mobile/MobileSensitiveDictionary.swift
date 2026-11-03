import SwiftUI

/// Each inline draft has its own focus and profile-bound mutation owner.
struct MobileSensitiveDictionaryEdit: Identifiable {
    let id = UUID()
    let entry: SensitiveDataDictionaryEntry?
}

/// The enclosing privacy Form owns the draft and clears it at profile concealment.
struct MobileSensitiveDictionarySettings: View {
    @Binding var edit: MobileSensitiveDictionaryEdit?
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var mutationSettings = SettingsStore.shared.boundToCurrentPrivateProfile()
    @Environment(\.theme) private var theme
    @State private var error: String?

    var body: some View {
        dictionarySection
        Section {
            ForEach(SensitiveBusinessGroupCatalog.groups) { group in
                NavigationLink {
                    MobileSensitiveBusinessGroupSettings(group: group)
                } label: {
                    VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                        Text(PichiLocalization.text(group.titleKey))
                        Text(PichiLocalization.text(settings.sensitiveBusinessGroupIDs.contains(group.id) ? "Enabled" : "Off"))
                            .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    }
                }.accessibilityIdentifier("privacy.groups.\(group.id)")
            }
        } header: {
            Text(PichiLocalization.text("Expression groups"))
        } footer: {
            MobileSettingsFooter(PichiLocalization.text("Choose expression groups for text cleanup. Supported topics also clean related sentences on this device. Review before sharing."))
        }
    }

    private var dictionarySection: some View {
        Section {
            ForEach(settings.sensitiveDataDictionaryEntries) { entry in
                if let draft = edit, draft.entry?.id == entry.id {
                    editor(draft)
                } else {
                    Button { error = nil; edit = .init(entry: entry) } label: {
                        HStack {
                            Text(entry.phrase).foregroundStyle(theme.palette.primaryText)
                            Spacer()
                            Image(systemName: "pencil").foregroundStyle(theme.palette.secondaryText)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.entry.\(entry.id)")
                        .swipeActions {
                            Button(PichiLocalization.text("Delete"), role: .destructive) {
                                do { try mutationSettings.removeSensitiveDataDictionaryPhrase(id: entry.id); settings.objectWillChange.send() }
                                catch { self.error = PichiLocalization.text("Could not update the private dictionary.") }
                            }.accessibilityIdentifier("privacy.dictionary.delete")
                        }
                }
            }
            if let draft = edit, draft.entry == nil {
                editor(draft)
            } else {
                Button { error = nil; edit = .init(entry: nil) } label: {
                    Label(PichiLocalization.text("Add word or phrase"), systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        .foregroundStyle(theme.palette.accentText)
                }.buttonStyle(.plain).accessibilityIdentifier("privacy.dictionary.add")
            }
            if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
                .accessibilityIdentifier("privacy.dictionary.error") }
        } header: {
            Text(PichiLocalization.text("Words and phrases for cleanup"))
        } footer: {
            MobileSettingsFooter(PichiLocalization.text("Words and their Russian forms are cleaned from new transcripts when data cleanup is enabled. Recognized topics also clean related sentences. Everything runs on this device."))
        }
    }

    private func editor(_ draft: MobileSensitiveDictionaryEdit) -> some View {
        MobileSensitiveDictionaryInlineEditor(draft: draft, saved: {
            settings.objectWillChange.send()
            edit = nil
        }, cancel: { edit = nil })
            .id(draft.id)
    }
}

/// A local row reuses existing dictionary operations; keyboard focus belongs to this draft.
private struct MobileSensitiveDictionaryInlineEditor: View {
    let draft: MobileSensitiveDictionaryEdit
    let saved: () -> Void
    let cancel: () -> Void
    @StateObject private var settings = SettingsStore.shared.boundToCurrentPrivateProfile()
    @Environment(\.theme) private var theme
    @State private var phrase: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(draft: MobileSensitiveDictionaryEdit, saved: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.draft = draft; self.saved = saved; self.cancel = cancel
        _phrase = State(initialValue: draft.entry?.phrase ?? "")
    }

    private var canSave: Bool { !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
            HStack(spacing: theme.metrics.spacing.xs) {
                TextField(PichiLocalization.text("Word or phrase"), text: $phrase)
                    .font(theme.typography.body)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).submitLabel(.done)
                    .onSubmit { save() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("privacy.dictionary.phrase")
                Button { save() } label: {
                    Image(systemName: "checkmark.circle.fill").imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(canSave ? theme.palette.accentText : theme.palette.secondaryText)
                    .disabled(!canSave).accessibilityLabel(PichiLocalization.text("Save"))
                    .accessibilityIdentifier("privacy.dictionary.save")
                Button { focused = false; cancel() } label: {
                    Image(systemName: "xmark.circle").imageScale(.large)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(theme.palette.secondaryText)
                    .accessibilityLabel(PichiLocalization.text("Cancel"))
                    .accessibilityIdentifier("privacy.dictionary.cancel")
            }
            if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
                .accessibilityIdentifier("privacy.dictionary.error") }
        }.accessibilityIdentifier("privacy.dictionary.inlineEditor")
            .onAppear { focused = true }
            .onDisappear { focused = false }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let entry = draft.entry { try settings.updateSensitiveDataDictionaryPhrase(id: entry.id, phrase: phrase) }
            else { try settings.addSensitiveDataDictionaryPhrase(phrase) }
            focused = false
            saved()
        } catch {
            self.error = PichiLocalization.text("Use a unique phrase of up to 16 words and 256 characters. The dictionary can contain up to 128 entries.")
            focused = true
        }
    }
}

/// A stable destination owns its controls; catalog vocabulary stays unmodified user-facing data.
private struct MobileSensitiveBusinessGroupSettings: View {
    let group: SensitiveBusinessGroup
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var mutationSettings = SettingsStore.shared.boundToCurrentPrivateProfile()
    @Environment(\.theme) private var theme
    @State private var error: String?
    @State private var editingExpressions = false

    var body: some View {
        Form {
            Section {
                Toggle(PichiLocalization.text("Clean this group's expressions"), isOn: Binding(
                    get: { settings.sensitiveBusinessGroupIDs.contains(group.id) },
                    set: { enabled in
                        do { try mutationSettings.setSensitiveBusinessGroup(id: group.id, enabled: enabled); settings.objectWillChange.send(); self.error = nil }
                        catch { self.error = PichiLocalization.text("Could not update privacy rules. The existing rules were kept.") }
                    }))
                    .accessibilityIdentifier("privacy.groups.\(group.id).enabled")
                if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning) }
            } footer: {
                MobileSettingsFooter(PichiLocalization.text(group.descriptionKey))
            }
            Section {
                Button { editingExpressions = true } label: {
                    Label(PichiLocalization.text("Edit expressions"), systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).edit")
                ForEach(settings.sensitiveBusinessGroupTerms(id: group.id), id: \.self) { term in
                    Text(term).textSelection(.enabled)
                }
            } header: {
                Text(PichiLocalization.text("Expressions for cleanup"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("The listed expressions and their Russian forms are cleaned from text, including quotations, denials and training examples."))
            }
            Section {
                ForEach(group.contextualExamples, id: \.self) { example in Text(example).textSelection(.enabled) }
            } header: {
                Text(PichiLocalization.text("Examples that need context"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("These examples explain the context. Supported groups clean related sentences automatically. Other groups clean the listed expressions and their word forms."))
            }
        }.mobileSettingsPage()
            .navigationTitle(PichiLocalization.text(group.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("privacy.groups.\(group.id).detail")
            .sheet(isPresented: $editingExpressions) {
                MobileSensitiveBusinessGroupEditor(group: group)
            }
    }
}

/// Drafts do not change enabled rules until the existing settings operation saves them.
private struct MobileSensitiveBusinessGroupEditor: View {
    let group: SensitiveBusinessGroup
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var mutationSettings = SettingsStore.shared.boundToCurrentPrivateProfile()
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var expressions: String
    @State private var error: String?

    init(group: SensitiveBusinessGroup) {
        self.group = group
        _expressions = State(initialValue: SettingsStore.shared.sensitiveBusinessGroupTerms(id: group.id).joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $expressions)
                        .font(theme.typography.body)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 240)
                        .accessibilityLabel(PichiLocalization.text("Expressions for cleanup"))
                        .accessibilityIdentifier("privacy.groups.\(group.id).expressions")
                } header: {
                    Text(PichiLocalization.text(group.titleKey))
                } footer: {
                    MobileSettingsFooter(PichiLocalization.text("Use one expression per line. Groups can contain up to 128 expressions in total. Changes stay on this device and apply to new recordings."))
                }
                Section {
                    Button { expressions = group.terms.joined(separator: "\n"); self.error = nil } label: {
                        Text(PichiLocalization.text("Restore suggested expressions"))
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).restore")
                    if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning) }
                }
            }.mobileSettingsPage()
                .navigationTitle(PichiLocalization.text("Edit group expressions"))
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("privacy.groups.\(group.id).editor")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Text(PichiLocalization.text("Cancel")).font(theme.typography.body)
                                .fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: {
                            Text(PichiLocalization.text("Save")).font(theme.typography.body)
                                .fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).save")
                    }
                }
        }
    }

    private func save() {
        let terms = expressions.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            if terms == group.terms { try mutationSettings.resetSensitiveBusinessGroupTerms(id: group.id) }
            else { try mutationSettings.replaceSensitiveBusinessGroupTerms(id: group.id, terms: terms) }
            settings.objectWillChange.send()
            dismiss()
        } catch {
            self.error = PichiLocalization.text("Could not save group expressions. Use unique expressions of up to 16 words and 256 characters, with at most 128 expressions across all groups. The existing rules were kept.")
        }
    }
}
