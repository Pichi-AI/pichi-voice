import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Retains an admitted capture's controller while hiding private pixels, focus and accessibility.
/// Rebuild child state only after the new source set commits; concealment alone cannot unmount
/// the owner responsible for finishing the old recording and its local persistence.
struct PrivateProfileRoot<Content: View>: View {
    @ObservedObject var services: AppServices
    @ObservedObject var profiles: PrivateProfileService
    @Environment(\.theme) private var theme
    @State private var stopping = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // A hidden SwiftUI child still runs its tasks. Mount its private readers only
            // after initial admission/key restoration, so a guest launch cannot consume
            // the one history refresh while access is closed. Later concealment keeps
            // this subtree mounted to retain the admitted capture's owner.
            if services.hasRestoredAccount {
                content()
                    .id(profiles.sourceRevision)
                    .opacity(profiles.isPrivateDataVisible ? 1 : 0)
                    .allowsHitTesting(profiles.isPrivateDataVisible)
                    .disabled(!profiles.isPrivateDataVisible)
                    .accessibilityHidden(!profiles.isPrivateDataVisible)
                    .background(PrivateProfileFocusBoundary(isVisible: profiles.isPrivateDataVisible))
            }
            if !profiles.isPrivateDataVisible || !services.hasRestoredAccount {
                theme.palette.windowBackground.ignoresSafeArea()
                VStack(spacing: theme.metrics.spacing.lg) {
                    Image(systemName: "lock.fill").foregroundStyle(theme.palette.secondaryText)
                    if services.hasActivePrivateCapture {
                        Button(PichiLocalization.text("Stop Recording")) {
                            stopping = true
                            Task { await services.stopPrivateCaptureAndLogout(); stopping = false }
                        }.buttonStyle(.borderedProminent).disabled(stopping)
                    } else {
                        if !services.hasRestoredAccount || profiles.isTransitioning || stopping { ProgressView() }
                        else {
                            Button(PichiLocalization.text("Continue")) {
                                stopping = true
                                Task { await services.retryPrivateProfileCleanupAndLogout(); stopping = false }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }.font(theme.typography.body)
            }
        }
        .task(id: profiles.sourceRevision) {
            await services.restoreAccountBeforePrivateUI()
            await services.restorePrivateSourcesAfterCommit()
        }
    }
}

// Release only this root's window responder. Other application windows and the retained
// capture owner are independent of the concealed editor's keyboard focus.
#if os(macOS)
private struct PrivateProfileFocusBoundary: NSViewRepresentable {
    let isVisible: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if !isVisible { view.window?.makeFirstResponder(nil) }
    }
}
#else
private struct PrivateProfileFocusBoundary: UIViewRepresentable {
    let isVisible: Bool
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        if !isVisible { view.window?.endEditing(true) }
    }
}
#endif
