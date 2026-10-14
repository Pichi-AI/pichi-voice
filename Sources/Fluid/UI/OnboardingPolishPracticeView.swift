import SwiftUI

/// The shortcut stays above the example; recording reveals and focuses the editor.
struct OnboardingPolishPracticeView: View {
    @Binding var finalText: String
    let practice: OnboardingPolishPractice
    let isRunning: Bool
    let isProcessing: Bool
    let isActive: Bool
    let shortcutDisplay: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @FocusState private var isEditorFocused: Bool
    @State private var hasActivated = false
    @State private var isKeyPressed = false

    private var blue: Color { self.theme.palette.accent }
    private var status: String {
        if !self.hasActivated { return PichiLocalization.format("Press %@ to begin.", self.shortcutDisplay) }
        if self.isRunning { return "Listening" }
        if self.isProcessing { return "Polishing…" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Let’s try a few examples.")
                .font(.fluidSystem(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(self.theme.palette.primaryText)
            HStack(spacing: 18) {
                OnboardingShortcutKeycap(text: self.shortcutDisplay, isPressed: self.isKeyPressed, isListening: self.isRunning)
                self.recordingStatus
            }
            VStack(alignment: .leading, spacing: 16) {
                if self.hasActivated {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Say this", systemImage: "quote.opening")
                            .font(.fluidSystem(size: 13, weight: .semibold))
                            .foregroundStyle(self.theme.palette.primaryText)
                        Text(PichiLocalization.text(self.practice.example.spoken))
                            .font(.fluidSystem(size: 17))
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) {
                                Capsule().fill(self.blue.opacity(0.38)).frame(width: 2)
                            }
                    }
                    self.editor
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        }
        .padding(28)
        .frame(maxWidth: 680, alignment: .leading)
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.25), value: self.hasActivated)
        .onAppear {
            if self.practice.result != nil { self.hasActivated = true }
        }
        .onChange(of: self.practice.index) { _, _ in
            self.finalText = ""
            self.isEditorFocused = self.hasActivated && self.isActive
        }
        .onChange(of: self.isActive) { _, active in
            if active && self.isRunning { self.revealExample() }
            self.isEditorFocused = active && self.hasActivated
        }
        .task(id: self.isRunning) {
            self.isKeyPressed = false
            guard self.isActive, self.isRunning else { return }
            self.revealExample()
            guard !self.reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.055)) { self.isKeyPressed = true }
            do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) { self.isKeyPressed = false }
        }
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if self.hasActivated && (self.isRunning || self.isProcessing) {
            HStack(spacing: 8) {
                Image(systemName: self.isRunning ? "waveform" : "sparkles")
                    .font(.fluidSystem(size: 15, weight: .medium))
                    .foregroundStyle(self.theme.palette.accentText)
                    .symbolEffect(.variableColor, options: .repeating, isActive: self.isRunning && self.isActive && self.scenePhase == .active && !self.reduceMotion)
                    .accessibilityHidden(true)
                Text(PichiLocalization.text(self.status))
                    .font(.fluidSystem(size: 14, weight: .medium))
                    .foregroundStyle(self.theme.palette.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(self.theme.palette.cardBackground, in: Capsule())
            .overlay(Capsule().stroke(self.blue.opacity(0.09), lineWidth: 1))
            .accessibilityElement(children: .combine)
        } else if !self.hasActivated {
            Text(PichiLocalization.text(self.status))
                .font(.fluidSystem(size: 14, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private func revealExample() {
        self.hasActivated = true
        self.isEditorFocused = true
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: self.$finalText)
                .font(.fluidSystem(size: 16))
                .foregroundStyle(self.theme.palette.primaryText)
                .scrollContentBackground(.hidden)
                .focused(self.$isEditorFocused)
                .padding(12)
                .accessibilityLabel("Dictation practice text")
                .accessibilityHint("Your dictation appears here automatically. You can also edit it.")
            if self.finalText.isEmpty {
                Text("Your words appear here…")
                    .font(.fluidSystem(size: 16))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 180)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(self.isEditorFocused ? self.blue.opacity(0.8) : self.theme.palette.cardBorder)
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
    }
}
