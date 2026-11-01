//
//  NearbyConnectionManager.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import Network
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
		self.name=info.name ?? "Quick Share"
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
		let rawDeviceType:Int=Int(data[0] & 0x0e) >> 1
		self.name=deviceName
		self.deviceType=RemoteDeviceInfo.DeviceType.fromRawValue(value: rawDeviceType)
		var offset=1+16
		if hasName{
			offset=offset+1+deviceNameLength
		}
		var qrCodeData:Data?=nil
		while data.count-offset>=2{ // read TLV records, if any
			let type=data[offset]
			let length=Int(data[offset+1])
			offset=offset+2
			guard data.count-offset>=length else { return nil }
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

public protocol MainAppDelegate{
	func obtainUserConsent(for transfer:TransferMetadata, from device:RemoteDeviceInfo)
	func incomingTransfer(id:String, didFinishWith error:Error?)
	func receivedFile(url:URL, transferID:String)
	func incomingProgress(id:String, progress:Double)
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

public class NearbyConnectionManager : NSObject, InboundNearbyConnectionDelegate, OutboundNearbyConnectionDelegate{
	
	private var tcpListener:NWListener?
	public var statusHandler:((String)->Void)?
	public let endpointID:[UInt8]=generateEndpointID()
	public var discoveryStatusHandler:((String)->Void)?
    public var visibilityStatusHandler:((Bool,String)->Void)?
    private var isRegistered=false
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
		tcpListener=nil
		super.init()
	}
	
    static func networkIssue(_ error:NWError)->String {
        if case .dns(let code)=error, code == -65570 {
            return "Lokales Netzwerk ist gesperrt. Öffne iOS-Einstellungen → Datenschutz & Sicherheit → Lokales Netzwerk und erlaube DropQuick."
        }
        return "Netzwerk wartet: \(error.localizedDescription). Prüfe WLAN und VPN und starte die Suche erneut."
    }
    public func becomeVisible(){
        guard tcpListener == nil else {return}
        do {
            let parameters=NWParameters.tcp
            parameters.includePeerToPeer=true
            let listener=try NWListener(using:parameters)
            tcpListener=listener
            let bytes:[UInt8]=[0x23]+endpointID+[0xfc,0x9f,0x5e,0,0]
            let info=EndpointInfo(name:DeviceIdentity.name,deviceType:.phone)
            let txt=NetService.data(fromTXTRecord:["n":Data(info.serialize().urlSafeBase64EncodedString().utf8)])
            listener.service=NWListener.Service(name:Data(bytes).urlSafeBase64EncodedString(),type:"_FC9F5ED42C8A._tcp",domain:"local.",txtRecord:txt)
            visibilityStatusHandler?(false,"Sichtbarkeit wird im Netzwerk angemeldet…")
            listener.serviceRegistrationUpdateHandler = { [weak self,weak listener] change in
                guard let self=self,let listener=listener,self.tcpListener === listener else {return}
                switch change {
                case .add(_):
                    self.isRegistered=true
                    self.visibilityStatusHandler?(true,"Im lokalen Netzwerk sichtbar")
                case .remove(_):
                    self.isRegistered=false
                    self.visibilityStatusHandler?(false,"Netzwerk-Ankündigung unterbrochen – suche erneut")
                @unknown default: break
                }
            }
            listener.stateUpdateHandler = { [weak self,weak listener] state in
                guard let self=self,let listener=listener,self.tcpListener === listener else {return}
                switch state {
                case .waiting(let error):self.visibilityStatusHandler?(false,Self.networkIssue(error))
                case .failed(let error):
                    self.visibilityStatusHandler?(false,Self.networkIssue(error))
                    self.tcpListener=nil;listener.cancel()
                default:break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self=self,self.activeConnections.count<4 else {connection.cancel();return}
                let conn=InboundNearbyConnection(connection:connection,id:UUID().uuidString)
                self.activeConnections[conn.id]=conn;conn.delegate=self;conn.start()
            }
            listener.start(queue:.main)
        } catch {visibilityStatusHandler?(false,"Sichtbarkeit fehlgeschlagen: \(error.localizedDescription)")}
    }

	private static func generateEndpointID()->[UInt8]{
		var id:[UInt8]=[]
		let alphabet="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".compactMap {UInt8($0.asciiValue!)}
		for _ in 0...3{
			id.append(alphabet[Int.random(in: 0..<alphabet.count)])
		}
		return id
	}
	
	func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, connection: InboundNearbyConnection) {
		guard let delegate=mainAppDelegate else {return}
		delegate.obtainUserConsent(for: transfer, from: device)
	}
	
	func connectionWasTerminated(connection:InboundNearbyConnection, error:Error?){
		guard let delegate=mainAppDelegate else {return}
		delegate.incomingTransfer(id: connection.id, didFinishWith: error)
		activeConnections.removeValue(forKey: connection.id)
	}
	
	public func cancelIncomingTransfers(){
        let connections=Array(activeConnections.values)
        NearbyConnection.dispatchQueue.async {for connection in connections {connection.lastError=NearbyError.canceled(reason:.userCanceled);connection.disconnect()}}
    }
    public func becomeHidden(){
        let listener=tcpListener;tcpListener=nil;listener?.cancel()
        isRegistered=false
        visibilityStatusHandler?(false,"Nicht sichtbar")
    }
    func receivedFile(url:URL, connection:InboundNearbyConnection) {
        DispatchQueue.main.async {self.mainAppDelegate?.receivedFile(url:url, transferID:connection.id)}
    }
    func incomingProgress(connection:InboundNearbyConnection, progress:Double) {
        DispatchQueue.main.async {self.mainAppDelegate?.incomingProgress(id:connection.id, progress:progress)}
    }
    public func submitUserConsent(transferID:String, accept:Bool){
		guard let conn=activeConnections[transferID] else {return}
		conn.submitUserConsent(accepted: accept)
	}
	
    public func startDeviceDiscovery(){
        discoveryRefCount+=1
        if discoveryRefCount==1 {restartDeviceDiscovery()}
    }
    public func restartDeviceDiscovery(){
        guard discoveryRefCount>0 else {return}
        let previous=browser;browser=nil;previous?.cancel()
        let ids=Array(foundServices.keys);foundServices.removeAll()
        for id in ids {for delegate in shareExtensionDelegates {delegate.removeDevice(id:id)}}
        discoveryStatusHandler?("Netzwerksuche wird gestartet…")
        let parameters=NWParameters.tcp;parameters.includePeerToPeer=true
        let next=NWBrowser(for:.bonjourWithTXTRecord(type:"_FC9F5ED42C8A._tcp",domain:"local."),using:parameters)
        browser=next
        next.stateUpdateHandler = { [weak self,weak next] state in
            guard let self=self,let next=next,self.browser === next else {return}
            switch state {
            case .ready:self.discoveryStatusHandler?("Netzwerksuche aktiv – Android: Quick Share → Empfangen")
            case .waiting(let error),.failed(let error):self.discoveryStatusHandler?(Self.networkIssue(error))
            default:break
            }
        }
        next.browseResultsChangedHandler = { [weak self,weak next] results,_ in
            guard let self=self,let next=next,self.browser === next else {return}
            let liveIDs=Set(results.compactMap{self.endpointID(for:$0)})
            for id in Array(self.foundServices.keys) where !liveIDs.contains(id) {
                self.foundServices.removeValue(forKey:id)
                for delegate in self.shareExtensionDelegates {delegate.removeDevice(id:id)}
            }
            for result in results {self.maybeAddFoundDevice(service:result)}
        }
        next.start(queue:.main)
    }

	public func stopDeviceDiscovery(){
		guard discoveryRefCount>0 else {return}
		discoveryRefCount-=1
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
		guard let transfer=outgoingTransfers.removeValue(forKey:id) else {return}
		NearbyConnection.dispatchQueue.async {transfer.connection.cancel()}
	}
	
	private func endpointID(for service:NWBrowser.Result)->String?{
		guard case let NWEndpoint.service(name: serviceName, type: _, domain: _, interface: _)=service.endpoint else {return nil}
		guard let nameData=Data.dataFromUrlSafeBase64(serviceName) else {return nil}
		guard nameData.count>=10 else {return nil}
		let pcp=nameData[0]
		guard pcp==0x23 else {return nil}
		guard let endpointID=String(data:nameData.subdata(in:1..<5),encoding:.ascii) else {return nil}
		let serviceIDHash=nameData.subdata(in: 5..<8)
		guard serviceIDHash==Data([0xFC, 0x9F, 0x5E]) else {return nil}
		return endpointID
	}
	
	private func maybeAddFoundDevice(service:NWBrowser.Result){
		#if DEBUG
		#endif
		for interface in service.interfaces{
			if case .loopback=interface.type{
				#if DEBUG
				#endif
				return
			}
		}
		guard let endpointID=endpointID(for: service), endpointID != String(bytes:self.endpointID, encoding:.ascii) else {return}
		#if DEBUG
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
		guard let info=foundServices[deviceID], !urls.isEmpty else {delegate.connectionFailed(with:NearbyError.protocolError("Device unavailable")); return}
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
	
    func outboundConnectionWasEstablished(connection:OutboundNearbyConnection) {
        DispatchQueue.main.async {
            guard let transfer=self.outgoingTransfers[connection.id] else {return}
            transfer.delegate.connectionWasEstablished(pinCode:connection.pinCode ?? "----")
        }
    }
    func outboundConnectionTransferAccepted(connection:OutboundNearbyConnection) {
        DispatchQueue.main.async {self.outgoingTransfers[connection.id]?.delegate.transferAccepted()}
    }
    func outboundConnection(connection:OutboundNearbyConnection,transferProgress:Double) {
        DispatchQueue.main.async {self.outgoingTransfers[connection.id]?.delegate.transferProgress(progress:transferProgress)}
    }
    func outboundConnection(connection:OutboundNearbyConnection,failedWithError:Error) {
        DispatchQueue.main.async {
            guard let transfer=self.outgoingTransfers.removeValue(forKey:connection.id) else {return}
            transfer.delegate.connectionFailed(with:failedWithError)
        }
    }
    func outboundConnectionTransferFinished(connection:OutboundNearbyConnection) {
        DispatchQueue.main.async {
            guard let transfer=self.outgoingTransfers.removeValue(forKey:connection.id) else {return}
            transfer.delegate.transferFinished()
        }
    }
}
