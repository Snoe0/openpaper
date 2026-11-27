import AppKit
import CanvasCore

/// The zoom level, with zoom out / in / fit buttons.
@MainActor
final class ZoomSection: PanelSection {
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFit: (() -> Void)?

    private let percent = Theme.label("100%")

    init() {
        super.init(title: "Zoom")
        percent.font = .monospacedDigitSystemFont(ofSize: Theme.bodySize, weight: .regular)
        let out = Theme.iconButton("minus", tooltip: "Zoom Out (⌘−)", target: self, action: #selector(zoomOutClicked))
        let `in` = Theme.iconButton("plus", tooltip: "Zoom In (⌘=)", target: self, action: #selector(zoomInClicked))
        let fit = Theme.button("Fit", target: self, action: #selector(fitClicked))
        fit.toolTip = "Zoom to Fit (⇧1)"
        addContent(Theme.row([percent, NSView(), out, `in`, fit]))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ scale: CGFloat) {
        percent.stringValue = ZoomSteps.percent(scale)
    }

    @objc private func zoomInClicked() { onZoomIn?() }
    @objc private func zoomOutClicked() { onZoomOut?() }
    @objc private func fitClicked() { onFit?() }
}
