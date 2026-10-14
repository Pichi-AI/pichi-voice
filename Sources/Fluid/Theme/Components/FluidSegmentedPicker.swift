import AppKit
import SwiftUI

/// Native segmented selection with owned, opaque label surfaces. AppKit can
/// flatten SwiftUI label styling and keep white ink over a pale selected tint.
/// The native bezel, focus, keyboard tracking and accessibility remain intact.
struct FluidSegmentedPicker<Selection: Hashable>: NSViewRepresentable {
    let title: String
    let options: [(value: Selection, title: String)]
    @Binding var selection: Selection
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.cell = FluidSegmentedCell(textCell: "")
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.update(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        self.update(control, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let native = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? native.width, height: native.height)
    }

    private func update(_ control: NSSegmentedControl, coordinator: Coordinator) {
        coordinator.parent = self
        if control.segmentCount != self.options.count { control.segmentCount = self.options.count }
        if control.font != self.theme.typography.nativeBodySmallFont { control.font = self.theme.typography.nativeBodySmallFont }
        if control.isEnabled != self.isEnabled { control.isEnabled = self.isEnabled }
        let accent = NSColor(self.theme.palette.accent)
        if control.selectedSegmentBezelColor != accent { control.selectedSegmentBezelColor = accent }
        control.setAccessibilityLabel(PichiLocalization.text(self.title, locale: self.interfaceLocale))
        for (index, option) in self.options.enumerated() {
            if control.label(forSegment: index) != option.title { control.setLabel(option.title, forSegment: index) }
            if control.width(forSegment: index) != 0 { control.setWidth(0, forSegment: index) }
            if control.isEnabled(forSegment: index) != self.isEnabled { control.setEnabled(self.isEnabled, forSegment: index) }
        }
        let selected = self.options.firstIndex { $0.value == self.selection } ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
        (control.cell as? FluidSegmentedCell)?.palette = self.theme.palette
        control.needsDisplay = true
    }

    final class Coordinator: NSObject {
        var parent: FluidSegmentedPicker
        init(_ parent: FluidSegmentedPicker) { self.parent = parent }

        @objc func selectionChanged(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard self.parent.isEnabled, control.isEnabled,
                  self.parent.options.indices.contains(index), control.isEnabled(forSegment: index)
            else { return }
            self.parent.selection = self.parent.options[index].value
        }
    }
}

private final class FluidSegmentedCell: NSSegmentedCell {
    var palette: AppTheme.Palette?

    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        guard let palette else {
            super.drawSegment(segment, inFrame: frame, with: controlView)
            return
        }
        let enabled = self.isEnabled && self.isEnabled(forSegment: segment)
        let selected = self.isSelected(forSegment: segment)
        let fill = enabled && selected ? palette.accent : palette.elevatedCardBackground
        let ink = enabled ? (selected ? palette.foreground(on: fill) : palette.primaryText) : palette.secondaryText
        // AppKit supplies the adjusted content rect. Keep its native bezel and
        // hit geometry; only own the surface directly under the label glyphs.
        (NSColor(fill).usingColorSpace(.sRGB) ?? NSColor(fill)).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 4, yRadius: frame.height / 4).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor(ink).usingColorSpace(.sRGB) ?? NSColor(ink),
            .paragraphStyle: paragraph,
        ]
        let label = self.label(forSegment: segment) ?? ""
        let height = min(frame.height, (label as NSString).size(withAttributes: attributes).height)
        (label as NSString).draw(in: NSRect(x: frame.minX, y: frame.midY - height / 2,
                                          width: frame.width, height: height), withAttributes: attributes)
    }
}
