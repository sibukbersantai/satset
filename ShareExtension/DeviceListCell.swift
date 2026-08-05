//
//  DeviceListCell.swift
//  ShareExtension
//
//  Created by Grishka on 20.09.2023.
//

import Cocoa

class DeviceListCell:NSCollectionViewItem {
	public var clickHandler:(()->Void)?
	private var trackingArea:NSTrackingArea?

	private static var accent:NSColor { NSColor(named: "AccentColor") ?? .controlAccentColor }

    override func viewDidLoad() {
        super.viewDidLoad()
		let btn:NSButton=view as! NSButton
		btn.isEnabled=true
		btn.setButtonType(.momentaryPushIn)
		btn.action=#selector(onClick)
		btn.target=self
		// Satset styling: a flat rounded tile that tints on hover, rather than the stock
		// push-button bezel upstream uses.
		btn.isBordered=false
		btn.wantsLayer=true
		btn.layer?.cornerRadius=12
		btn.layer?.backgroundColor=NSColor.clear.cgColor
    }

	override func viewDidLayout() {
		super.viewDidLayout()
		if let existing=trackingArea { view.removeTrackingArea(existing) }
		let area=NSTrackingArea(rect: view.bounds,
								options: [.mouseEnteredAndExited, .activeInActiveApp],
								owner: self, userInfo: nil)
		view.addTrackingArea(area)
		trackingArea=area
	}

	override func mouseEntered(with event: NSEvent) {
		view.layer?.backgroundColor=DeviceListCell.accent.withAlphaComponent(0.14).cgColor
	}

	override func mouseExited(with event: NSEvent) {
		view.layer?.backgroundColor=NSColor.clear.cgColor
	}


	@IBAction func onClick(_ sender:Any?){
		guard let handler=clickHandler else {return}
		handler()
	}
}
