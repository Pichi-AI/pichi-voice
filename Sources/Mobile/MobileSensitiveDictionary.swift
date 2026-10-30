import SwiftUI
import UniformTypeIdentifiers

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
            MobileSettingsFooter(PichiLocalization.text("Groups are off until you enable them. Review the expressions in each group. Context examples are explanations, not additional dictionary rules."))
        }
        Section {
            NavigationLink {
                MobileSensitiveTopicSettings()
            } label: {
                Label(PichiLocalization.text("Hide topics"), systemImage: "text.magnifyingglass")
            }.accessibilityIdentifier("privacy.topics.open")
        } header: {
            Text(PichiLocalization.text("Experimental topic detection"))
        } footer: {
            MobileSettingsFooter(PichiLocalization.text("A local topic model can hide complete sentences about selected topics, including indirect wording. This experimental mode may miss phrases or hide unrelated sentences."))
        }
    }

    private var dictionarySection: some View {
        Section {
            ForEach(settings.sensitiveDataDictionaryEntries) { entry in
                Button { edit(entry) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                            Text(entry.phrase).foregroundStyle(theme.palette.primaryText)
                            Text(PichiLocalization.text(entry.matchMode == .wordForms ? "Russian word forms" : "Exact wording"))
                                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        }
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
    @State private var matchMode: SensitiveDictionaryMatchMode
    @State private var error: String?

    init(entry: SensitiveDataDictionaryEntry?) {
        self.entry = entry
        _phrase = State(initialValue: entry?.phrase ?? "")
        _matchMode = State(initialValue: entry?.matchMode ?? .wordForms)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(PichiLocalization.text("Word or phrase"), text: $phrase, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("privacy.dictionary.phrase")
                Picker(PichiLocalization.text("Matching"), selection: $matchMode) {
                    Text(PichiLocalization.text("Russian word forms")).tag(SensitiveDictionaryMatchMode.wordForms)
                    Text(PichiLocalization.text("Exact wording")).tag(SensitiveDictionaryMatchMode.exact)
                }.accessibilityIdentifier("privacy.dictionary.matchMode")
                Text(PichiLocalization.text(matchMode == .wordForms
                    ? "Recognized Russian words include case and number forms. Unknown words and other languages use exact wording; add any needed variants. Parts of other words are kept."
                    : "Whole words and phrases are matched without case sensitivity. Parts of other words are kept."))
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
            if let entry { try settings.updateSensitiveDataDictionaryPhrase(id: entry.id, phrase: phrase, matchMode: matchMode) }
            else { try settings.addSensitiveDataDictionaryPhrase(phrase, matchMode: matchMode) }
            dismiss()
        } catch {
            // No private phrase is copied into errors or logs.
            self.error = PichiLocalization.text("Use a unique phrase of up to 16 words and 256 characters. The dictionary can contain up to 128 entries.")
        }
    }
}

/// A stable destination owns its controls; catalog vocabulary stays unmodified user-facing data.
private struct MobileSensitiveBusinessGroupSettings: View {
    let group: SensitiveBusinessGroup
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var error: String?
    @State private var editingExpressions = false

    var body: some View {
        Form {
            Section {
                Toggle(PichiLocalization.text("Hide this group's expressions"), isOn: Binding(
                    get: { settings.sensitiveBusinessGroupIDs.contains(group.id) },
                    set: { enabled in
                        do { try settings.setSensitiveBusinessGroup(id: group.id, enabled: enabled); error = nil }
                        catch { error = PichiLocalization.text("Could not update privacy rules. The existing rules were kept.") }
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
                Text(PichiLocalization.text("Expressions to hide"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("The listed expressions also match supported Russian word forms. They are hidden in quotations, denials and training examples too."))
            }
            Section {
                ForEach(group.contextualExamples, id: \.self) { example in Text(example).textSelection(.enabled) }
            } header: {
                Text(PichiLocalization.text("Examples that need context"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("These examples are not added as dictionary rules. Topic detection is a separate optional setting."))
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
                        .accessibilityLabel(PichiLocalization.text("Expressions to hide"))
                        .accessibilityIdentifier("privacy.groups.\(group.id).expressions")
                } header: {
                    Text(PichiLocalization.text(group.titleKey))
                } footer: {
                    MobileSettingsFooter(PichiLocalization.text("Use one expression per line. Groups can contain up to 128 expressions in total. Changes stay on this device and apply to new recordings."))
                }
                Section {
                    Button { expressions = group.terms.joined(separator: "\n"); error = nil } label: {
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
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: {
                            Text(PichiLocalization.text("Save")).font(theme.typography.body)
                        }.buttonStyle(.plain).accessibilityIdentifier("privacy.groups.\(group.id).save")
                    }
                }
        }
    }

    private func save() {
        let terms = expressions.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            if terms == group.terms { try settings.resetSensitiveBusinessGroupTerms(id: group.id) }
            else { try settings.replaceSensitiveBusinessGroupTerms(id: group.id, terms: terms) }
            dismiss()
        } catch {
            error = PichiLocalization.text("Could not save group expressions. Use unique expressions of up to 16 words and 256 characters, with at most 128 expressions across all groups. The existing rules were kept.")
        }
    }
}

/// The Form owns one importer presentation. All operations use the shared settings service.
private struct MobileSensitiveTopicSettings: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(PichiLocalization.text(settings.sensitiveTopicClassifierInstalled ? "Local topic model is ready" : "Import a local topic model to begin"))
                Button { importing = true } label: {
                    Label(PichiLocalization.text("Import local topic model"), systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("privacy.topics.import")
                if let error { Text(error).font(theme.typography.caption).foregroundStyle(theme.palette.warning) }
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("The model stays on this device. Importing it does not enable any topic. Settings apply to new recordings."))
            }
            Section {
                ForEach(availableGroups) { group in
                    Toggle(PichiLocalization.text(group.titleKey), isOn: Binding(
                        get: { settings.sensitiveTopicClassifierIDs.contains(group.id) },
                        set: { enabled in
                            do { try settings.setSensitiveTopicClassifier(id: group.id, enabled: enabled); error = nil }
                            catch { error = PichiLocalization.text("Could not update privacy rules. The existing rules were kept.") }
                        }))
                        .accessibilityIdentifier("privacy.topics.\(group.id).enabled")
                }
                if settings.sensitiveTopicClassifierInstalled && availableGroups.isEmpty {
                    Text(PichiLocalization.text("This model has no supported topics."))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            } header: {
                Text(PichiLocalization.text("Topics to hide"))
            } footer: {
                MobileSettingsFooter(
                    PichiLocalization.text("Topic detection hides complete sentences, including quotations and denials. Live text waits for enough context. A processing error stops publication instead of showing unfiltered text."),
                    PichiLocalization.text("This experimental model does not guarantee recognition of every indirect phrase. Review the cleaned transcript before sharing it."))
            }
        }.mobileSettingsPage()
            .navigationTitle(PichiLocalization.text("Hide topics"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("privacy.topics.detail")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .failure:
                    error = PichiLocalization.text("Could not import the local topic model. The existing model and rules were kept.")
                case .success(let url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { try settings.importSensitiveTopicClassifier(from: url); error = nil }
                    catch { error = PichiLocalization.text("Could not import the local topic model. The existing model and rules were kept.") }
                }
            }
    }

    private var availableGroups: [SensitiveBusinessGroup] {
        SensitiveBusinessGroupCatalog.groups.filter { settings.sensitiveTopicClassifierAvailableIDs.contains($0.id) }
    }
}
