//
//  NearbyConnectionManager.swift
//  Satset
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import Network
import System
import CryptoKit
import SwiftECC

public struct RemoteDeviceInfo{
	public let name:String
	public let type:DeviceType
	public let qrCodeData:Data?
	public var id:String?
	
	init(name: String, type: DeviceType, id: String? = nil) {
		self.name = name
		self.type = type
		self.id = id
		self.qrCodeData = nil
	}
	
	init(info:EndpointInfo, id: String? = nil){
		self.name=info.name!
		self.type=info.deviceType
		self.qrCodeData=info.qrCodeData
		self.id=id
	}
	
	public enum DeviceType:Int32{
		case unknown=0
		case phone
		case tablet
		case computer
		
		public static func fromRawValue(value:Int) -> DeviceType{
			switch value {
			case 0:
				return .unknown
			case 1:
				return .phone
			case 2:
				return .tablet
			case 3:
				return .computer
			default:
				return .unknown
			}
		}
	}
}


public enum NearbyError:Error{
	case protocolError(_ message:String)
	case requiredFieldMissing(_ message:String)
	case ukey2
	case inputOutput
	case canceled(reason:CancellationReason)
	
	public enum CancellationReason{
		case userRejected, userCanceled, notEnoughSpace, unsupportedType, timedOut
	}
}

public struct TransferMetadata{
	public let files:[FileMetadata]
	public let id:String
	public let pinCode:String?
	public let textDescription:String?
	
	init(files: [FileMetadata], id: String, pinCode: String?, textDescription: String?=nil){
		self.files = files
		self.id = id
		self.pinCode = pinCode
		self.textDescription = textDescription
	}
}

public struct FileMetadata{
	public let name:String
	public let size:Int64
	public let mimeType:String
}

struct FoundServiceInfo{
	let service:NWBrowser.Result
	var device:RemoteDeviceInfo?
}

struct OutgoingTransferInfo{
	let service:NWBrowser.Result
	let device:RemoteDeviceInfo
	let connection:OutboundNearbyConnection
	let delegate:ShareExtensionDelegate
}

struct EndpointInfo{
	var name:String?
	let deviceType:RemoteDeviceInfo.DeviceType
	let qrCodeData:Data?
	
	init(name: String, deviceType: RemoteDeviceInfo.DeviceType){
		self.name = name
		self.deviceType = deviceType
		self.qrCodeData=nil
	}
	
	init?(data:Data){
		guard data.count>17 else {return nil}
		let hasName=(data[0] & 0x10)==0
		let deviceNameLength:Int
		let deviceName:String?
		if hasName{
			deviceNameLength=Int(data[17])
			guard data.count>=deviceNameLength+18 else {return nil}
			guard let _deviceName=String(data: data[18..<(18+deviceNameLength)], encoding: .utf8) else {return nil}
			deviceName=_deviceName
		}else{
			deviceNameLength=0
			deviceName=nil
		}
		let rawDeviceType:Int=Int(data[0] & 7) >> 1
		self.name=deviceName
		self.deviceType=RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)
		var offset=1+16
		if hasName{
			offset=offset+1+deviceNameLength
		}
		var qrCodeData:Data?=nil
		while data.count-offset>2{ // read TLV records, if any
			let type=data[offset]
			let length=Int(data[offset+1])
			offset=offset+2
			if data.count-offset>=length{
				if type==1{ // QR code data
					qrCodeData=data.subdata(in: offset..<offset+length)
				}
				offset=offset+length
			}
		}
		self.qrCodeData=qrCodeData
	}
	
	func serialize()->Data{
		// 1 byte: Version(3 bits)|Visibility(1 bit)|Device Type(3 bits)|Reserved(1 bits)
		// Device types: unknown=0, phone=1, tablet=2, laptop=3
		var endpointInfo:[UInt8]=[UInt8(deviceType.rawValue << 1)]
		// 16 bytes: unknown random bytes
		for _ in 0...15{
			endpointInfo.append(UInt8.random(in: 0...255))
		}
		// Device name in UTF-8 prefixed with 1-byte length
		var nameChars=[UInt8](name!.utf8)
		if nameChars.count>255{
			nameChars=[UInt8](nameChars[0..<255])
		}
		endpointInfo.append(UInt8(nameChars.count))
		for ch in nameChars{
			endpointInfo.append(UInt8(ch))
		}
		return Data(endpointInfo)
	}
}

/// Whether the current network can carry Nearby Share at all. Discovery is mDNS based,
/// so it needs a network that forwards multicast between its clients.
public enum NetworkCompatibility:Equatable{
	/// Nothing obviously wrong. Not a promise -- client isolation on a normal router
	/// looks identical from here and can only be found by failing to see anything.
	case ok
	/// No usable network at all.
	case offline
	/// Apple's Personal Hotspot, which never bridges multicast between its clients,
	/// so Android can never see this Mac. Identified by its fixed 172.20.10.0/28 subnet.
	case personalHotspot
	/// Low Data Mode or a metered connection. Discovery usually still works, worth surfacing.
	case constrained
}

public protocol MainAppDelegate{
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo)
	func incomingTransfer(id:String, didFinishWith error:Error?)
	func networkCompatibilityChanged(to compatibility:NetworkCompatibility)
}

public extension MainAppDelegate{
	// Default so existing conformances keep compiling.
	func networkCompatibilityChanged(to compatibility:NetworkCompatibility){}
}

public protocol ShareExtensionDelegate:AnyObject{
	func addDevice(device:RemoteDeviceInfo)
	func removeDevice(id:String)
	func startTransferWithQrCode(device:RemoteDeviceInfo)
	func connectionWasEstablished(pinCode:String)
	func connectionFailed(with error:Error)
	func transferAccepted()
	func transferProgress(progress:Double)
	func transferFinished()
}

public class NearbyConnectionManager : NSObject, NetServiceDelegate, InboundNearbyConnectionDelegate, OutboundNearbyConnectionDelegate{
	
	private var tcpListener:NWListener?
	public let endpointID:[UInt8]=generateEndpointID()
	private var mdnsService:NetService?
	// Advertising has to survive network changes, sleep/wake and mDNSResponder restarts,
	// otherwise the Mac silently stops being discoverable until the app is relaunched.
	private var isVisible=false
	private var listenerRestartDelay:TimeInterval=1
	private var pathMonitor:NWPathMonitor?
	private var advertisedInterfaces:Set<String>=[]
	public private(set) var networkCompatibility:NetworkCompatibility = .ok
	// These four are owned by the main queue. Connection and listener callbacks arrive on
	// background queues, so they hop onto main before touching them -- Swift dictionaries
	// are not thread-safe, and concurrent mutation corrupts memory rather than just
	// losing an entry.
	private var activeConnections:[String:InboundNearbyConnection]=[:]
	private var foundServices:[String:FoundServiceInfo]=[:]
	private var shareExtensionDelegates:[ShareExtensionDelegate]=[]
	private var outgoingTransfers:[String:OutgoingTransferInfo]=[:]
	public var mainAppDelegate:(any MainAppDelegate)?
	private var discoveryRefCount=0
	
	private var browser:NWBrowser?
	
	private var qrCodePublicKey:ECPublicKey?
	private var qrCodePrivateKey:ECPrivateKey?
	private var qrCodeAdvertisingToken:Data?
	private var qrCodeNameEncryptionKey:SymmetricKey?
	private var qrCodeData:Data?
	
	public static let shared=NearbyConnectionManager()
	
	override init() {
		super.init()
	}

	public func becomeVisible(){
		guard !isVisible else {return}
		isVisible=true
		listenerRestartDelay=1
		startTCPListener()
		startPathMonitor()
	}

	/// Stops advertising and stops accepting new incoming transfers. Sending is unaffected --
	/// discovery uses a separate browser, so you can still share files while invisible.
	/// Transfers already in progress are left alone.
	public func becomeInvisible(){
		isVisible=false
		teardownMDNS()
		let listener=tcpListener
		tcpListener=nil
		listener?.cancel()
		// Keep monitoring so network warnings still update while hidden.
		startPathMonitor()
	}

	private func startTCPListener(){
		guard isVisible, tcpListener==nil else {return}
		let listener:NWListener
		do{
			listener=try NWListener(using: NWParameters(tls: .none))
		}catch{
			NSLog("Satset: failed to create TCP listener: \(error)")
			scheduleListenerRestart()
			return
		}
		tcpListener=listener
		// The listener runs on a background queue, but all advertising state is owned by
		// the main queue -- NetService needs a live run loop to deliver its callbacks anyway.
		listener.stateUpdateHandler={[weak self] (state:NWListener.State) in
			DispatchQueue.main.async {
				guard let self=self, self.tcpListener===listener else {return}
				switch state{
				case .ready:
					self.listenerRestartDelay=1
					self.initMDNS()
				case let .failed(error):
					NSLog("Satset: TCP listener failed: \(error)")
					self.restartListener()
				case .cancelled:
					self.teardownMDNS()
				case let .waiting(error):
					NSLog("Satset: TCP listener waiting: \(error)")
				default:
					break
				}
			}
		}
		listener.newConnectionHandler={[weak self] (connection:NWConnection) in
			guard let self=self else {return}
			let id=UUID().uuidString
			let conn=InboundNearbyConnection(connection: connection, id: id)
			conn.delegate=self
			DispatchQueue.main.async {
				// Registered before starting, so callbacks can never arrive before the lookup works.
				self.activeConnections[id]=conn
				conn.start()
			}
		}
		listener.start(queue: .global(qos: .utility))
	}

	private func restartListener(){
		let listener=tcpListener
		tcpListener=nil
		listener?.cancel()
		teardownMDNS()
		scheduleListenerRestart()
	}

	private func scheduleListenerRestart(){
		guard isVisible else {return}
		let delay=listenerRestartDelay
		listenerRestartDelay=min(delay*2, 30)
		DispatchQueue.main.asyncAfter(deadline: .now()+delay){
			self.startTCPListener()
		}
	}

	/// Watches for Wi-Fi changes, VPN toggles and sleep/wake, all of which invalidate
	/// the existing mDNS registration without the listener itself ever failing.
	private func startPathMonitor(){
		guard pathMonitor==nil else {return}
		let monitor=NWPathMonitor()
		pathMonitor=monitor
		monitor.pathUpdateHandler={[weak self] path in
			guard let self=self else {return}
			let interfaces=Set(path.availableInterfaces.map{$0.name})
			let compatibility=Self.evaluateCompatibility(of: path)
			DispatchQueue.main.async {
				if compatibility != self.networkCompatibility{
					self.networkCompatibility=compatibility
					NSLog("Satset: network compatibility is now \(compatibility)")
					self.mainAppDelegate?.networkCompatibilityChanged(to: compatibility)
				}
				guard self.isVisible else {return}
				guard path.status == .satisfied else {return}
				guard interfaces != self.advertisedInterfaces else {return}
				self.advertisedInterfaces=interfaces
				if let listener=self.tcpListener{
					if case .ready = listener.state {
						self.initMDNS()
					}
				}else{
					self.startTCPListener()
				}
			}
		}
		monitor.start(queue: .global(qos: .utility))
	}

	private static func evaluateCompatibility(of path:NWPath)->NetworkCompatibility{
		guard path.status == .satisfied else {return .offline}
		if isOnPersonalHotspot() {return .personalHotspot}
		if path.isConstrained || path.isExpensive {return .constrained}
		return .ok
	}

	/// iOS Personal Hotspot always hands out addresses on 172.20.10.0/28. That subnet is a
	/// reliable fingerprint -- no ordinary router uses it.
	private static func isOnPersonalHotspot()->Bool{
		var addrs:UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&addrs)==0, let first=addrs else {return false}
		defer {freeifaddrs(addrs)}
		for ptr in sequence(first: first, next: {$0.pointee.ifa_next}){
			let flags=Int32(ptr.pointee.ifa_flags)
			guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else {continue}
			guard let sa=ptr.pointee.ifa_addr, sa.pointee.sa_family==UInt8(AF_INET) else {continue}
			var host=[CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
							  nil, 0, NI_NUMERICHOST)==0 else {continue}
			if String(cString: host).hasPrefix("172.20.10."){
				return true
			}
		}
		return false
	}

	/// The name Android shows for this Mac. `Host.current()` caches aggressively and can
	/// return nil, which used to be force-unwrapped.
	private static func localDeviceName()->String{
		if let name=Host.current().localizedName, !name.isEmpty{
			return name
		}
		var name=ProcessInfo.processInfo.hostName
		if let dot=name.firstIndex(of: "."){
			name=String(name[name.startIndex..<dot])
		}
		return name.isEmpty ? "Mac" : name
	}

	private func teardownMDNS(){
		guard let service=mdnsService else {return}
		// Clear the delegate first so the resulting netServiceDidStop doesn't recurse.
		service.delegate=nil
		mdnsService=nil
		service.stop()
	}
	
	private static func generateEndpointID()->[UInt8]{
		var id:[UInt8]=[]
		let alphabet="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".compactMap {UInt8($0.asciiValue!)}
		for _ in 0...3{
			id.append(alphabet[Int.random(in: 0..<alphabet.count)])
		}
		return id
	}
	
	private func initMDNS(){
		let nameBytes:[UInt8]=[
			0x23, // PCP
			endpointID[0], endpointID[1], endpointID[2], endpointID[3],
			0xFC, 0x9F, 0x5E, // Service ID hash
			0, 0
		]
		let name=Data(nameBytes).urlSafeBase64EncodedString()
		let endpointInfo=EndpointInfo(name: Self.localDeviceName(), deviceType: .computer)

		guard let listenerPort=tcpListener?.port else {
			NSLog("Satset: TCP listener has no port yet, not advertising")
			return
		}
		teardownMDNS()
		let port:Int32=Int32(listenerPort.rawValue)
		let service=NetService(domain: "", type: "_FC9F5ED42C8A._tcp.", name: name, port: port)
		mdnsService=service
		service.delegate=self
		service.setTXTRecord(NetService.data(fromTXTRecord: [
			"n": endpointInfo.serialize().urlSafeBase64EncodedString().data(using: .utf8)!
		]))
		// Explicitly scheduled on the main run loop so the delegate callbacks below run at all.
		service.schedule(in: .main, forMode: .common)
		service.publish()
	}

	public func netServiceDidPublish(_ sender: NetService) {
		NSLog("Satset: advertising as \(sender.name) on port \(sender.port)")
	}

	public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
		// Previously silent: the Mac would just never show up on Android with no indication why.
		NSLog("Satset: failed to advertise over mDNS: \(errorDict)")
		DispatchQueue.main.asyncAfter(deadline: .now()+5){
			guard self.isVisible, self.mdnsService===sender else {return}
			self.initMDNS()
		}
	}

	public func netServiceDidStop(_ sender: NetService) {
		guard isVisible, mdnsService===sender else {return}
		NSLog("Satset: mDNS advertising stopped unexpectedly, re-publishing")
		DispatchQueue.main.asyncAfter(deadline: .now()+1){
			guard self.isVisible, self.mdnsService===sender else {return}
			self.initMDNS()
		}
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
		// Arrives on the connection queue; the app delegate posts notifications and keeps
		// its own state, so it must not be called from there.
		DispatchQueue.main.async {
			guard let delegate=self.mainAppDelegate else {return}
			delegate.obtainUserConsent(for: transfer, from: device)
		}
	}

	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?){
		DispatchQueue.main.async {
			self.mainAppDelegate?.incomingTransfer(id: connection.id, didFinishWith: error)
			self.activeConnections.removeValue(forKey: connection.id)
		}
	}

	/// Safe to call from any queue -- notification delegate callbacks aren't guaranteed
	/// to arrive on the main thread.
	public func submitUserConsent(transferID:String, accept:Bool){
		let work={
			guard let conn=self.activeConnections[transferID] else {return}
			conn.submitUserConsent(accepted: accept)
		}
		if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
	}
	
	public func startDeviceDiscovery(){
		if discoveryRefCount==0{
			foundServices.removeAll()
			if browser==nil{
				browser=NWBrowser(for: .bonjourWithTXTRecord(type: "_FC9F5ED42C8A._tcp.", domain: nil), using: .tcp)
				browser?.browseResultsChangedHandler={newResults, changes in
					for change in changes{
						switch change{
						case let .added(res):
							self.maybeAddFoundDevice(service: res)
						case let .removed(res):
							self.maybeRemoveFoundDevice(service: res)
						default:
							break
						}
					}
				}
			}
			browser?.start(queue: .main)
		}
		discoveryRefCount+=1
	}
	
	public func stopDeviceDiscovery(){
		discoveryRefCount-=1
		assert(discoveryRefCount>=0)
		if discoveryRefCount==0{
			browser?.cancel()
			browser=nil
		}
	}
	
	public func addShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		shareExtensionDelegates.append(delegate)
		for service in foundServices.values{
			guard let device=service.device else {continue}
			delegate.addDevice(device: device)
		}
	}
	
	public func removeShareExtensionDelegate(_ delegate:ShareExtensionDelegate){
		shareExtensionDelegates.removeAll(where: {$0===delegate})
	}
	
	public func cancelOutgoingTransfer(id:String){
		guard let transfer=outgoingTransfers[id] else {return}
		transfer.connection.cancel()
	}
	
	private func endpointID(for service:NWBrowser.Result)->String?{
		guard case let NWEndpoint.service(name: serviceName, type: _, domain: _, interface: _)=service.endpoint else {return nil}
		guard let nameData=Data.dataFromUrlSafeBase64(serviceName) else {return nil}
		guard nameData.count>=10 else {return nil}
		let pcp=nameData[0]
		guard pcp==0x23 else {return nil}
		let endpointID=String(data: nameData.subdata(in: 1..<5), encoding: .ascii)!
		let serviceIDHash=nameData.subdata(in: 5..<8)
		guard serviceIDHash==Data([0xFC, 0x9F, 0x5E]) else {return nil}
		return endpointID
	}
	
	private func maybeAddFoundDevice(service:NWBrowser.Result){
		#if DEBUG
		print("found service \(service)")
		#endif
		for interface in service.interfaces{
			if case .loopback=interface.type{
				#if DEBUG
				print("ignoring localhost service")
				#endif
				return
			}
		}
		guard let endpointID=endpointID(for: service) else {return}
		#if DEBUG
		print("service name is valid, endpoint ID \(endpointID)")
		#endif
		var foundService=FoundServiceInfo(service: service)
		
		guard case let NWBrowser.Result.Metadata.bonjour(txtRecord)=service.metadata else {return}
		guard let endpointInfoEncoded=txtRecord.dictionary["n"] else {return}
		guard let endpointInfoSerialized=Data.dataFromUrlSafeBase64(endpointInfoEncoded) else {return}
		guard var endpointInfo=EndpointInfo(data: endpointInfoSerialized) else {return}
		
		var deviceInfo:RemoteDeviceInfo?
		if let _=endpointInfo.name{
			deviceInfo=addFoundDevice(foundService: &foundService, endpointInfo: endpointInfo, endpointID: endpointID)
		}
		
		if let qrData=endpointInfo.qrCodeData, let _=qrCodeAdvertisingToken{
#if DEBUG
			print("Device has QR data: \(qrData.base64EncodedString()), our advertising token is \(qrCodeAdvertisingToken!.base64EncodedString())")
#endif
			if qrData==qrCodeAdvertisingToken!{
				if let deviceInfo=deviceInfo{
					for delegate in shareExtensionDelegates{
						delegate.startTransferWithQrCode(device: deviceInfo)
					}
				}
			}else if qrData.count>28{
				do{
					let box=try AES.GCM.SealedBox(combined: qrData)
					let decryptedName=try AES.GCM.open(box, using: qrCodeNameEncryptionKey!, authenticating: qrCodeAdvertisingToken!)
					guard let name=String.init(data: decryptedName, encoding: .utf8) else {return}
					endpointInfo.name=name
					let deviceInfo=addFoundDevice(foundService: &foundService, endpointInfo: endpointInfo, endpointID: endpointID)
					for delegate in shareExtensionDelegates{
						delegate.startTransferWithQrCode(device: deviceInfo)
					}
				}catch{
#if DEBUG
					print("Error decrypting QR code data of an invisible device: \(error)")
#endif
				}
			}
		}
	}
	
	private func addFoundDevice(foundService:inout FoundServiceInfo, endpointInfo:EndpointInfo, endpointID:String) -> RemoteDeviceInfo{
		let deviceInfo=RemoteDeviceInfo(info: endpointInfo, id: endpointID)
		foundService.device=deviceInfo
		foundServices[endpointID]=foundService
		for delegate in shareExtensionDelegates{
			delegate.addDevice(device: deviceInfo)
		}
		return deviceInfo
	}
	
	private func maybeRemoveFoundDevice(service:NWBrowser.Result){
		guard let endpointID=endpointID(for: service) else {return}
		guard let _=foundServices.removeValue(forKey: endpointID) else {return}
		for delegate in shareExtensionDelegates {
			delegate.removeDevice(id: endpointID)
		}
	}
	
	public func generateQrCodeKey() -> String{
		let domain=Domain.instance(curve: .EC256r1)
		let (pubKey, privKey)=domain.makeKeyPair()
		qrCodePublicKey=pubKey
		qrCodePrivateKey=privKey
		var keyData=Data()
		keyData.append(contentsOf: [0, 0, 2])
		let keyBytes=Data(pubKey.w.x.asSignedBytes())
		// Sometimes, for some keys, there will be a leading zero byte. Strip that, Android really hates it (it breaks the endpoint info)
		keyData.append(keyBytes.suffixOfAtMost(numBytes: 32))
		
		let ikm=SymmetricKey(data: keyData)
		qrCodeAdvertisingToken=NearbyConnection.hkdf(inputKeyMaterial: ikm, salt: Data(), info: "advertisingContext".data(using: .utf8)!, outputByteCount: 16).data()
		qrCodeNameEncryptionKey=NearbyConnection.hkdf(inputKeyMaterial: ikm, salt: Data(), info: "encryptionKey".data(using: .utf8)!, outputByteCount: 16)
		qrCodeData=keyData
		
		return keyData.urlSafeBase64EncodedString()
	}
	
	public func clearQrCodeKey(){
		qrCodePublicKey=nil
		qrCodePrivateKey=nil
		qrCodeAdvertisingToken=nil
		qrCodeNameEncryptionKey=nil
		qrCodeData=nil
	}
	
	public func startOutgoingTransfer(deviceID:String, delegate:ShareExtensionDelegate, urls:[URL]){
		guard let info=foundServices[deviceID] else {return}
		let tcp=NWProtocolTCP.Options.init()
		tcp.noDelay=true
		let nwconn=NWConnection(to: info.service.endpoint, using: NWParameters(tls: .none, tcp: tcp))
		let conn=OutboundNearbyConnection(connection: nwconn, id: deviceID, urlsToSend: urls)
		conn.delegate=self
		conn.qrCodePrivateKey=qrCodePrivateKey
		let transfer=OutgoingTransferInfo(service: info.service, device: info.device!, connection: conn, delegate: delegate)
		outgoingTransfers[deviceID]=transfer
		conn.start()
	}
	
	func outboundConnectionWasEstablished(connection: OutboundNearbyConnection) {
		DispatchQueue.main.async {
			guard let transfer=self.outgoingTransfers[connection.id] else {return}
			guard let pinCode=connection.pinCode else {return}
			transfer.delegate.connectionWasEstablished(pinCode: pinCode)
		}
	}

	func outboundConnectionTransferAccepted(connection: OutboundNearbyConnection) {
		DispatchQueue.main.async {
			guard let transfer=self.outgoingTransfers[connection.id] else {return}
			transfer.delegate.transferAccepted()
		}
	}

	func outboundConnection(connection: OutboundNearbyConnection, transferProgress: Double) {
		DispatchQueue.main.async {
			guard let transfer=self.outgoingTransfers[connection.id] else {return}
			transfer.delegate.transferProgress(progress: transferProgress)
		}
	}

	func outboundConnection(connection: OutboundNearbyConnection, failedWithError: Error) {
		DispatchQueue.main.async {
			guard let transfer=self.outgoingTransfers.removeValue(forKey: connection.id) else {return}
			transfer.delegate.connectionFailed(with: failedWithError)
		}
	}

	func outboundConnectionTransferFinished(connection: OutboundNearbyConnection) {
		DispatchQueue.main.async {
			guard let transfer=self.outgoingTransfers.removeValue(forKey: connection.id) else {return}
			transfer.delegate.transferFinished()
		}
	}
}

