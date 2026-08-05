//
//  QRCodeWindowController.swift
//  Satset
//
//  Shows the Quick Share QR code from the menu bar, so an Android device can be made
//  discoverable *before* picking files. macOS can't send the BLE advertisement Android
//  waits for, so scanning this code is what wakes Quick Share up.
//

import Cocoa
import CoreImage
import NearbyShare

private func isDark(_ view: NSView) -> Bool {
	view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

/// Faint brand-tinted backdrop. Without it the white QR card below is invisible against
/// the default near-white window background in light mode.
private class BrandBackgroundView: NSView {
	override func draw(_ dirtyRect: NSRect) {
		let colors: [NSColor] = isDark(self)
			? [NSColor(srgbRed: 0.118, green: 0.086, blue: 0.137, alpha: 1),
			   NSColor(srgbRed: 0.145, green: 0.094, blue: 0.125, alpha: 1)]
			: [NSColor(srgbRed: 0.992, green: 0.969, blue: 1.000, alpha: 1),
			   NSColor(srgbRed: 1.000, green: 0.961, blue: 0.980, alpha: 1)]
		NSGradient(starting: colors[0], ending: colors[1])?.draw(in: bounds, angle: -60)
	}
}

/// White rounded card behind the QR code. It stays white in both appearances on purpose --
/// phone cameras need the contrast, so this one thing is deliberately not themed.
private class QRCardView: NSView {
	override func draw(_ dirtyRect: NSRect) {
		let r = bounds.insetBy(dx: 6, dy: 6)
		NSGraphicsContext.saveGraphicsState()
		let shadow = NSShadow()
		shadow.shadowColor = NSColor.black.withAlphaComponent(isDark(self) ? 0.55 : 0.20)
		shadow.shadowBlurRadius = 14
		shadow.shadowOffset = NSSize(width: 0, height: -3)
		shadow.set()
		let path = NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22)
		NSColor.white.setFill()
		path.fill()
		NSGraphicsContext.restoreGraphicsState()
	}
}

/// Capsule status line, tinted with the app accent once a device turns up.
private class StatusPill: NSView {
	private let label = NSTextField(labelWithString: "")
	private var tint: NSColor = .secondaryLabelColor

	init() {
		super.init(frame: .zero)
		label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
		label.alignment = .center
		label.lineBreakMode = .byTruncatingTail
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
			label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
			label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
			label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
		])
	}
	required init?(coder: NSCoder) { fatalError() }

	func set(_ text: String, tint: NSColor) {
		self.tint = tint
		label.stringValue = text
		label.textColor = tint
		needsDisplay = true
	}

	override func draw(_ dirtyRect: NSRect) {
		let r = bounds
		let path = NSBezierPath(roundedRect: r, xRadius: r.height/2, yRadius: r.height/2)
		tint.withAlphaComponent(isDark(self) ? 0.22 : 0.13).setFill()
		path.fill()
	}
}

class QRCodeWindowController: NSWindowController, ShareExtensionDelegate, NSWindowDelegate {

	private var pill: StatusPill!
	private var discovering = false

	private static var accent: NSColor { NSColor(named: "AccentColor") ?? .controlAccentColor }

	convenience init() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
							  styleMask: [.titled, .closable, .fullSizeContentView],
							  backing: .buffered,
							  defer: false)
		window.title = NSLocalizedString("QRCode.Title", value: "Make Android Discoverable", comment: "")
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isMovableByWindowBackground = true
		window.isReleasedWhenClosed = false
		self.init(window: window)

		// MARK: Wordmark
		let mark = NSImageView()
		mark.image = NSApp.applicationIconImage
		mark.translatesAutoresizingMaskIntoConstraints = false
		mark.widthAnchor.constraint(equalToConstant: 30).isActive = true
		mark.heightAnchor.constraint(equalToConstant: 30).isActive = true

		let wordmark = NSTextField(labelWithString: "Satset")
		wordmark.font = QRCodeWindowController.brandFont(size: 24)
		wordmark.textColor = .labelColor

		let header = NSStackView(views: [mark, wordmark])
		header.orientation = .horizontal
		header.spacing = 9
		header.alignment = .centerY

		// MARK: QR card
		let qrKey = NearbyConnectionManager.shared.generateQrCodeKey()
		let qrImage = NSImageView()
		qrImage.image = QRCodeWindowController.makeQRCode(
			from: "https://quickshare.google/qrcode#key=\(qrKey)", dimension: 260)
		qrImage.translatesAutoresizingMaskIntoConstraints = false

		let card = QRCardView()
		card.translatesAutoresizingMaskIntoConstraints = false
		card.addSubview(qrImage)
		NSLayoutConstraint.activate([
			card.widthAnchor.constraint(equalToConstant: 296),
			card.heightAnchor.constraint(equalToConstant: 296),
			qrImage.centerXAnchor.constraint(equalTo: card.centerXAnchor),
			qrImage.centerYAnchor.constraint(equalTo: card.centerYAnchor),
			qrImage.widthAnchor.constraint(equalToConstant: 260),
			qrImage.heightAnchor.constraint(equalToConstant: 260),
		])

		// MARK: Copy
		// A wrapping NSTextField's intrinsic width is its full single-line width, so without
		// an explicit width it overflows the stack's insets and touches the window edges.
		let textWidth: CGFloat = 296

		let headline = NSTextField(wrappingLabelWithString: NSLocalizedString(
			"QRCode.Headline", value: "Point your phone's camera here", comment: ""))
		headline.font = .systemFont(ofSize: 15, weight: .semibold)
		headline.alignment = .center
		headline.preferredMaxLayoutWidth = textWidth
		headline.translatesAutoresizingMaskIntoConstraints = false
		headline.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

		let detail = NSTextField(wrappingLabelWithString: NSLocalizedString(
			"QRCode.Instructions",
			value: "Quick Share opens on your phone and it becomes visible to this Mac. Then share your files as usual.",
			comment: ""))
		detail.alignment = .center
		detail.textColor = .secondaryLabelColor
		detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		detail.preferredMaxLayoutWidth = textWidth
		detail.translatesAutoresizingMaskIntoConstraints = false
		detail.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

		pill = StatusPill()
		pill.set(NSLocalizedString("QRCode.Waiting", value: "Waiting for a device…", comment: ""),
				 tint: .secondaryLabelColor)
		// A long device name must not push the capsule past the text column.
		pill.translatesAutoresizingMaskIntoConstraints = false
		pill.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true

		let stack = NSStackView(views: [header, card, headline, detail, pill])
		stack.orientation = .vertical
		stack.alignment = .centerX
		stack.spacing = 14
		stack.setCustomSpacing(20, after: header)
		stack.setCustomSpacing(18, after: card)
		stack.setCustomSpacing(8, after: headline)
		stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
		stack.translatesAutoresizingMaskIntoConstraints = false

		let content = BrandBackgroundView()
		content.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			stack.topAnchor.constraint(equalTo: content.topAnchor),
			stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
		])
		window.contentView = content
		window.delegate = self
		window.center()

		// Discovery is what lets us tell the user the scan actually worked.
		NearbyConnectionManager.shared.addShareExtensionDelegate(self)
		NearbyConnectionManager.shared.startDeviceDiscovery()
		discovering = true
	}

	/// Rounded system font where available -- gives the app its own voice rather than the
	/// default San Francisco look upstream uses.
	private static func brandFont(size: CGFloat) -> NSFont {
		let base = NSFont.systemFont(ofSize: size, weight: .bold)
		if #available(macOS 11.0, *),
		   let desc = base.fontDescriptor.withDesign(.rounded) {
			return NSFont(descriptor: desc, size: size) ?? base
		}
		return base
	}

	private static func makeQRCode(from string: String, dimension: CGFloat) -> NSImage? {
		guard let filter = CIFilter(name: "CIQRCodeGenerator"),
			  let data = string.data(using: .ascii) else {return nil}
		filter.setValue(data, forKey: "inputMessage")
		// The protocol notes say Google's own codes use low error correction.
		filter.setValue("L", forKey: "inputCorrectionLevel")
		guard let output = filter.outputImage else {return nil}
		let scale = dimension / output.extent.width
		let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		let rep = NSCIImageRep(ciImage: scaled)
		let image = NSImage(size: rep.size)
		image.addRepresentation(rep)
		return image
	}

	private func stopDiscovering() {
		guard discovering else {return}
		discovering = false
		NearbyConnectionManager.shared.removeShareExtensionDelegate(self)
		NearbyConnectionManager.shared.stopDeviceDiscovery()
		NearbyConnectionManager.shared.clearQrCodeKey()
	}

	func windowWillClose(_ notification: Notification) {
		stopDiscovering()
	}

	// MARK: - ShareExtensionDelegate

	func addDevice(device: RemoteDeviceInfo) {
		pill.set(String(format: NSLocalizedString(
			"QRCode.Found", value: "Found “%@” — ready to share", comment: ""),
			arguments: [device.name]), tint: QRCodeWindowController.accent)
	}

	func removeDevice(id: String) {}

	/// Fires when the device that scanned *this* code shows up, which is the strongest
	/// confirmation we can give that it worked.
	func startTransferWithQrCode(device: RemoteDeviceInfo) {
		addDevice(device: device)
	}

	func connectionWasEstablished(pinCode: String) {}
	func connectionFailed(with error: Error) {}
	func transferAccepted() {}
	func transferProgress(progress: Double) {}
	func transferFinished() {}
}
