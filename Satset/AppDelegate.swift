//
//  AppDelegate.swift
//  Satset
//
//  Created by Grishka on 08.04.2023.
//

import Cocoa
import UserNotifications
import NearbyShare

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MainAppDelegate{
	private var statusItem:NSStatusItem?
	private var activeIncomingTransfers:[String:TransferInfo]=[:]
	private var networkWarningItem:NSMenuItem?
	private var qrCodeWindowController:QRCodeWindowController?
	private var visibilityItem:NSMenuItem?
	private static let visibilityDefaultsKey="NDVisibleToEveryone"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
		let menu=NSMenu()
		let visibilityItem=NSMenuItem(title: NSLocalizedString("VisibleToEveryone", value: "Visible to everyone", comment: ""), action: #selector(toggleVisibility(_:)), keyEquivalent: "")
		visibilityItem.target=self
		menu.addItem(visibilityItem)
		self.visibilityItem=visibilityItem
		menu.addItem(withTitle: String(format: NSLocalizedString("DeviceName", value: "Device name: %@", comment: ""), arguments: [Host.current().localizedName ?? ProcessInfo.processInfo.hostName]), action: nil, keyEquivalent: "")

		// Hidden until something is actually wrong, so the menu stays quiet in the normal case.
		let warningItem=NSMenuItem(title: "", action: #selector(showNetworkWarningDetails(_:)), keyEquivalent: "")
		warningItem.target=self
		warningItem.isHidden=true
		menu.addItem(warningItem)
		networkWarningItem=warningItem

		menu.addItem(NSMenuItem.separator())
		let qrItem=NSMenuItem(title: NSLocalizedString("ShowQRCode", value: "Make Android Discoverable…", comment: ""), action: #selector(showQRCodeWindow(_:)), keyEquivalent: "")
		qrItem.target=self
		menu.addItem(qrItem)
		menu.addItem(NSMenuItem.separator())
		menu.addItem(withTitle: NSLocalizedString("Quit", value: "Quit Satset", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
		statusItem=NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem?.button?.image=NSImage(named: "MenuBarIcon")
		statusItem?.menu=menu
		statusItem?.behavior = .removalAllowed
		
		let nc=UNUserNotificationCenter.current()
		nc.requestAuthorization(options: [.alert, .sound]) { granted, err in
			if !granted{
				DispatchQueue.main.async {
					self.showNotificationsDeniedAlert()
				}
			}
		}
		nc.delegate=self
		let incomingTransfersCategory=UNNotificationCategory(identifier: "INCOMING_TRANSFERS", actions: [
			UNNotificationAction(identifier: "ACCEPT", title: NSLocalizedString("Accept", comment: ""), options: UNNotificationActionOptions.authenticationRequired),
			UNNotificationAction(identifier: "DECLINE", title: NSLocalizedString("Decline", comment: ""))
		], intentIdentifiers: [])
		let errorsCategory=UNNotificationCategory(identifier: "ERRORS", actions: [], intentIdentifiers: [])
		nc.setNotificationCategories([incomingTransfersCategory, errorsCategory])
		NearbyConnectionManager.shared.mainAppDelegate=self
		// Defaults to visible, matching the previous always-on behaviour.
		UserDefaults.standard.register(defaults: [AppDelegate.visibilityDefaultsKey: true])
		applyVisibility(UserDefaults.standard.bool(forKey: AppDelegate.visibilityDefaultsKey))
	}
	
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		statusItem?.isVisible=true
		return true
	}

    func applicationWillTerminate(_ aNotification: Notification) {
		UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
	
	// MARK: - Visibility

	@objc func toggleVisibility(_ sender:AnyObject?){
		let nowVisible = !UserDefaults.standard.bool(forKey: AppDelegate.visibilityDefaultsKey)
		UserDefaults.standard.set(nowVisible, forKey: AppDelegate.visibilityDefaultsKey)
		applyVisibility(nowVisible)
	}

	private func applyVisibility(_ visible:Bool){
		if visible{
			NearbyConnectionManager.shared.becomeVisible()
		}else{
			NearbyConnectionManager.shared.becomeInvisible()
		}
		visibilityItem?.state = visible ? .on : .off
		// Dim the menu bar icon so the current state is obvious without opening the menu.
		statusItem?.button?.appearsDisabled = !visible
	}

	@objc func showQRCodeWindow(_ sender:AnyObject?){
		if qrCodeWindowController==nil{
			qrCodeWindowController=QRCodeWindowController()
		}
		NSApp.activate(ignoringOtherApps: true)
		qrCodeWindowController?.showWindow(nil)
		qrCodeWindowController?.window?.makeKeyAndOrderFront(nil)
	}

	// MARK: - Network compatibility

	func networkCompatibilityChanged(to compatibility:NetworkCompatibility){
		guard let item=networkWarningItem else {return}
		guard let summary=AppDelegate.warningSummary(for: compatibility) else {
			item.isHidden=true
			return
		}
		item.title=summary
		item.isHidden=false
	}

	private static func warningSummary(for compatibility:NetworkCompatibility)->String?{
		switch compatibility{
		case .ok:
			return nil
		case .offline:
			return NSLocalizedString("Network.Offline", value: "⚠️ No network — not discoverable", comment: "")
		case .personalHotspot:
			return NSLocalizedString("Network.Hotspot", value: "⚠️ Hotspot: Android can't see this Mac — details…", comment: "")
		case .constrained:
			return NSLocalizedString("Network.Constrained", value: "⚠️ Metered network — details…", comment: "")
		}
	}

	@objc func showNetworkWarningDetails(_ sender:AnyObject?){
		let compatibility=NearbyConnectionManager.shared.networkCompatibility
		guard compatibility != .ok else {return}
		let alert=NSAlert()
		alert.alertStyle = .warning
		switch compatibility{
		case .personalHotspot:
			alert.messageText=NSLocalizedString("Network.Hotspot.Title", value: "Android can't discover this Mac here", comment: "")
			alert.informativeText=NSLocalizedString("Network.Hotspot.Message", value: "This Mac is on a Personal Hotspot. Hotspots pass multicast only one way: announcements from other devices reach this Mac, but this Mac's own announcements don't reach them. So your Android device will show “No people found” even though everything on this Mac is working.\n\nSending from this Mac usually still works — this Mac can see Android, so choose files and share via Satset.\n\nTo receive files, connect both devices to an ordinary Wi-Fi router.", comment: "")
		case .constrained:
			alert.messageText=NSLocalizedString("Network.Constrained.Title", value: "This network is metered", comment: "")
			alert.informativeText=NSLocalizedString("Network.Constrained.Message", value: "This Mac is on a connection marked as metered, or Low Data Mode is turned on. Discovery may be unreliable.\n\nIf Android can't find this Mac, try an ordinary Wi-Fi router.", comment: "")
		case .offline:
			alert.messageText=NSLocalizedString("Network.Offline.Title", value: "No network connection", comment: "")
			alert.informativeText=NSLocalizedString("Network.Offline.Message", value: "Satset needs a Wi-Fi network that both this Mac and your Android device are connected to.", comment: "")
		case .ok:
			return
		}
		// Client isolation on a normal router looks identical to a working network from here,
		// so say so rather than implying the check is exhaustive.
		alert.informativeText+=NSLocalizedString("Network.IsolationNote", value: "\n\nNote: some routers and most public/guest Wi-Fi block devices from seeing each other. That can't be detected from here — if discovery fails on an ordinary network, check for “client isolation” or “AP isolation” in your router settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("OK", value: "OK", comment: ""))
		NSApp.activate(ignoringOtherApps: true)
		alert.runModal()
	}

	func showNotificationsDeniedAlert(){
		let alert=NSAlert()
		alert.alertStyle = .critical
		alert.messageText=NSLocalizedString("NotificationsDenied.Title", value: "Notification Permission Required", comment: "")
		alert.informativeText=NSLocalizedString("NotificationsDenied.Message", value: "Satset needs to be able to display notifications for incoming file transfers. Please allow notifications in System Settings.", comment: "")
		alert.addButton(withTitle: NSLocalizedString("NotificationsDenied.OpenSettings", value: "Open settings", comment: ""))
		alert.addButton(withTitle: NSLocalizedString("Quit", value: "Quit Satset", comment: ""))
		let result=alert.runModal()
		if result==NSApplication.ModalResponse.alertFirstButtonReturn{
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
		}else if result==NSApplication.ModalResponse.alertSecondButtonReturn{
			NSApplication.shared.terminate(nil)
		}
	}
	
	func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
		let transferID=response.notification.request.content.userInfo["transferID"]! as! String
		NearbyConnectionManager.shared.submitUserConsent(transferID: transferID, accept: response.actionIdentifier=="ACCEPT")
		if response.actionIdentifier != "ACCEPT"{
			activeIncomingTransfers.removeValue(forKey: transferID)
		}
		completionHandler()
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
		let fileStr:String
		if let textTitle=transfer.textDescription{
			fileStr=textTitle
		}else if transfer.files.count==1{
			fileStr=transfer.files[0].name
		}else{
			fileStr=String.localizedStringWithFormat(NSLocalizedString("NFiles", value: "%d files", comment: ""), transfer.files.count)
		}
		let notificationContent=UNMutableNotificationContent()
		notificationContent.title="Satset"
		notificationContent.subtitle=String(format:NSLocalizedString("PinCode", value: "PIN: %@", comment: ""), arguments: [transfer.pinCode!])
		notificationContent.body=String(format: NSLocalizedString("DeviceSendingFiles", value: "%1$@ is sending you %2$@", comment: ""), arguments: [device.name, fileStr])
		notificationContent.sound = .default
		notificationContent.categoryIdentifier="INCOMING_TRANSFERS"
		notificationContent.userInfo=["transferID": transfer.id]
		if #available(macOS 11.0, *){
			NDNotificationCenterHackery.removeDefaultAction(notificationContent)
		}
		let notificationReq=UNNotificationRequest(identifier: "transfer_"+transfer.id, content: notificationContent, trigger: nil)
		UNUserNotificationCenter.current().add(notificationReq)
		self.activeIncomingTransfers[transfer.id]=TransferInfo(device: device, transfer: transfer)
	}
	
	func incomingTransfer(id: String, didFinishWith error: Error?) {
		guard let transfer=self.activeIncomingTransfers[id] else {return}
		if let error=error{
			let notificationContent=UNMutableNotificationContent()
			notificationContent.title=String(format: NSLocalizedString("TransferError", value: "Failed to receive files from %@", comment: ""), arguments: [transfer.device.name])
			if let ne=(error as? NearbyError){
				switch ne{
				case .inputOutput:
					notificationContent.body="I/O Error";
				case .protocolError(_):
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .requiredFieldMissing:
					notificationContent.body=NSLocalizedString("Error.Protocol", value: "Communication error", comment: "")
				case .ukey2:
					notificationContent.body=NSLocalizedString("Error.Crypto", value: "Encryption error", comment: "")
				case .canceled(reason: _):
					break; // can't happen for incoming transfers
				}
			}else{
				notificationContent.body=error.localizedDescription
			}
			notificationContent.categoryIdentifier="ERRORS"
			UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transferError_"+id, content: notificationContent, trigger: nil))
		}
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["transfer_"+id])
		self.activeIncomingTransfers.removeValue(forKey: id)
	}
}

struct TransferInfo{
	let device:RemoteDeviceInfo
	let transfer:TransferMetadata
}
