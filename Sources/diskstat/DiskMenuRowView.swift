import AppKit
import Darwin
import Foundation

/// Row views are only ever built and updated on the main thread.
@MainActor
final class DiskMenuRowView: NSView {
    /// The width is fixed, but the height follows the content — see
    /// `sizeToFitContent()`.
    private static let rowWidth: CGFloat = 340
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 8

    /// Tooltip for the clean button, in its idle state.
    ///
    /// One constant because it is set twice — on the button when the row is
    /// built, and again in `setBusy(_:)` when the button returns to idle. The
    /// two were the same string written out separately, so a change to one could
    /// leave the other describing the old behaviour.
    private static let cleanToolTip = "Clean and Eject"

    /// What VoiceOver announces for the clean button, in its idle state.
    ///
    /// Built once from the volume name and reused, because `setBusy(_:)` swaps
    /// the button's image and was giving the new image a bare "Clean" — so the
    /// name was announced the first time and silently dropped after the first
    /// clean. Needs storing rather than recomputing, since `setBusy(_:)` has no
    /// access to the `DiskUsage` it was built from.
    private let cleanAccessibilityLabel: String

    private let onEject: (() -> Void)?
    private let onClean: (() -> Void)?
    private let onCancel: (() -> Void)?

    private let detailsLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var ejectButton: NSButton?
    private var cleanButton: NSButton?

    private var normalDetails = ""
    private var normalPercent = ""
    private var isBusy = false

    init(
        disk: DiskUsage,
        formatter: ByteCountFormatter,
        onEject: (() -> Void)? = nil,
        onClean: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.onEject = onEject
        self.onClean = onClean
        self.onCancel = onCancel
        self.cleanAccessibilityLabel = "Clean \(disk.name)"
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 0))

        let used = formatter.string(fromByteCount: disk.usedBytes)
        let total = formatter.string(fromByteCount: disk.totalBytes)
        let percent = Int(round(disk.usedFraction * 100))

        // Don't mutate the workspace image's `size`: it is a shared, multi-rep
        // image (32 representations at 32pt), and resizing it defers the
        // representation re-resolution. Until that settles, the image view's
        // footprint is unstable and the volume name next to it shifts a few
        // points as the row appears. Pinning the view instead lets
        // `imageScaling` downscale the 32pt icon into a fixed 24pt slot.
        let iconView = NSImageView(image: NSWorkspace.shared.icon(forFile: disk.mountURL.path))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: disk.name)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // A label's default hugging priority is low, so in a `.fill` stack it
        // would absorb the slack and move when the icon resolves. Keep it at its
        // intrinsic width and let the spacer take up the difference.
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.textColor = .labelColor

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.distribution = .fill
        topRow.addArrangedSubview(iconView)
        topRow.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(spacer)

        let showEjectButton = disk.canEject

        if showEjectButton {
            let eject = NSButton(title: "", target: self, action: #selector(ejectTapped))
            eject.bezelStyle = .texturedRounded
            eject.isBordered = false
            eject.image = NSImage(
                systemSymbolName: "eject.fill",
                accessibilityDescription: "Eject \(disk.name)"
            )
            eject.contentTintColor = .secondaryLabelColor
            eject.setButtonType(.momentaryPushIn)
            eject.toolTip = "Eject \(disk.name)"
            eject.setContentHuggingPriority(.required, for: .horizontal)
            eject.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(eject)
            ejectButton = eject
        }

        if DiskCleaner.canClean(disk) {
            let clean = NSButton(title: "", target: self, action: #selector(cleanTapped))
            clean.bezelStyle = .texturedRounded
            clean.isBordered = false
            clean.image = NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: cleanAccessibilityLabel
            )
            clean.contentTintColor = .secondaryLabelColor
            clean.setButtonType(.momentaryPushIn)
            clean.toolTip = Self.cleanToolTip
            clean.setContentHuggingPriority(.required, for: .horizontal)
            clean.setContentCompressionResistancePriority(.required, for: .horizontal)
            topRow.addArrangedSubview(clean)
            cleanButton = clean
        }

        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = Double(percent)
        progress.controlSize = .regular
        progress.style = .bar

        normalDetails = "Used: \(used) of \(total)"
        normalPercent = "\(percent)% used"

        detailsLabel.stringValue = normalDetails
        detailsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.lineBreakMode = .byTruncatingTail

        percentLabel.stringValue = normalPercent
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)

        let bottomRow = NSStackView(views: [detailsLabel, percentLabel])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        bottomRow.distribution = .fill

        // The device is last, and omitted entirely when `diskutil` has not
        // answered, so the line reads "exFAT • GUID • disk4s2" or just
        // "exFAT • GUID" — never with a dangling separator.
        let metaLabel = NSTextField(labelWithString: Self.metaLine(for: disk))
        metaLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        let stack = self.stack
        [topRow, progress, bottomRow, metaLabel].forEach { stack.addArrangedSubview($0) }
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            // Deliberately no bottom pin. The row takes the height its content
            // needs, so a larger system font or a long volume name cannot be
            // clipped by a hardcoded frame.
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Fixed icon slot, so the row's layout is final on the first pass.
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        // The menu is assembled from these views, so the height must be right
        // before NSMenu measures the item.
        sizeToFitContent()
    }

    /// The filesystem line: `exFAT • GUID • disk4s2`.
    ///
    /// A static function rather than inline in `init` so it can be tested. The
    /// row is an `NSView` assembled in its initialiser, so nothing about what
    /// it actually renders is reachable from a test — an extracted function
    /// means the one rule worth pinning (no trailing separator when the device
    /// is unknown) is at least checkable.
    /// `nonisolated` because it builds a string and touches no AppKit state, so a
    /// test can call it without hopping to the main actor. The surrounding type
    /// is `@MainActor`; this one member is not.
    nonisolated static func metaLine(for disk: DiskUsage) -> String {
        var parts = [disk.fileSystem, disk.partitionMap]
        if let device = disk.deviceIdentifier {
            parts.append(device)
        }
        return parts.joined(separator: " • ")
    }

    override func layout() {
        super.layout()
        applyContentHeight()
    }

    private func sizeToFitContent() {
        layoutSubtreeIfNeeded()
        applyContentHeight()
    }

    /// `NSMenu` takes a custom item view's height from its frame, so a fixed
    /// frame silently clips anything taller than it. Not hypothetical: the
    /// content outgrew the hardcoded 104pt by 3pt at the current font settings,
    /// and would clip more at larger ones.
    private func applyContentHeight() {
        let needed = stack.frame.height + Self.verticalInset * 2
        guard needed > 0, abs(frame.height - needed) > 0.5 else { return }
        frame.size.height = needed
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func ejectTapped() {
        onEject?()
    }

    @objc private func cleanTapped() {
        if isBusy {
            onCancel?()
        } else {
            onClean?()
        }
    }

    /// Replaces the status line, used to report progress and the result.
    func setStatus(_ status: String, percent: String) {
        detailsLabel.stringValue = status
        percentLabel.stringValue = percent
    }

    /// Swaps the clean button for a cancel button while a clean is running.
    func setBusy(_ busy: Bool) {
        isBusy = busy

        ejectButton?.isEnabled = !busy
        cleanButton?.isEnabled = true
        cleanButton?.image = NSImage(
            systemSymbolName: busy ? "xmark.circle" : "sparkles",
            accessibilityDescription: busy ? "Cancel" : cleanAccessibilityLabel
        )
        cleanButton?.toolTip = busy ? "Cancel" : Self.cleanToolTip

        if !busy {
            setStatus(normalDetails, percent: normalPercent)
        }
    }
}
