import XCTest
import CryptoKit
@testable import DropQuick

final class DropQuickTests:XCTestCase {
    func testEndpointRoundTripAndDeviceType() {
        for type in [RemoteDeviceInfo.DeviceType.phone,.tablet,.computer] {
            let source=EndpointInfo(name:"Mamas Samsung 🥰",deviceType:type)
            let decoded=EndpointInfo(data:source.serialize())
            XCTAssertEqual(decoded?.name,source.name)
            XCTAssertEqual(decoded?.deviceType,type)
        }
    }
    func testMalformedEndpointIsRejected() {
        XCTAssertNil(EndpointInfo(data:Data()))
        XCTAssertNil(EndpointInfo(data:Data(repeating:0,count:17)))
        var truncated=EndpointInfo(name:"Test",deviceType:.phone).serialize()
        truncated.append(contentsOf:[1,200,0])
        XCTAssertNil(EndpointInfo(data:truncated))
    }
    func testRejectsTraversalAndControlCharacters() throws {
        for name in ["../private.txt","/tmp/x","..","a\\b","bad\u{0}.txt","",String(repeating:"x",count:241)] {
            XCTAssertThrowsError(try SafeFileName.validate(name),name)
        }
        XCTAssertEqual(try SafeFileName.validate("Urlaub 🏖️.jpg"),"Urlaub 🏖️.jpg")
    }
    func testURLSafeBase64() {
        let data=Data([0,255,254,1,25])
        let encoded=data.urlSafeBase64EncodedString()
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data.dataFromUrlSafeBase64(encoded),data)
    }
    func testHKDFMatchesRFC5869Vector() {
        let result=NearbyConnection.hkdf(inputKeyMaterial:SymmetricKey(data:Data(repeating:0x0b,count:22)),salt:Data(0...12),info:Data(0xf0...0xf9),outputByteCount:42).data()
        XCTAssertEqual(result.map{String(format:"%02x",$0)}.joined(),"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }
    func testPINAlwaysHasFourDigits() {
        for value:UInt8 in [0,1,127,128,255] {
            let pin=NearbyConnection.pinCodeFromAuthKey(SymmetricKey(data:Data(repeating:value,count:32)))
            XCTAssertEqual(pin.count,4)
            XCTAssertNotNil(Int(pin))
        }
    }
    func testHistoryRoundTrip() throws {
        let value=TransferRecord(direction:"Empfangen",peer:"Samsung",names:["Photo.jpg"],paths:[],state:"Abgeschlossen")
        let decoded=try JSONDecoder().decode(TransferRecord.self,from:JSONEncoder().encode(value))
        XCTAssertEqual(decoded.id,value.id)
        XCTAssertEqual(decoded.names,value.names)
    }
    func testBrowserEscapesNames() {
        XCTAssertEqual(BrowserPortal.escape("<script>\"&"),"&lt;script&gt;&quot;&amp;")
    }
}

// Runs the real encrypted protocol over loopback; does not claim stock-Android interop.
final class EncryptedLoopbackTests:XCTestCase {
    func testEncryptedMultiFileTransferIncludingEmptyFile() throws {
        let done=expectation(description:"Sender and receiver complete")
        done.expectedFulfillmentCount=3 // two received files plus sender completion
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let content=Data((0..<700_000).map{UInt8(truncatingIfNeeded:$0)})
        let first=folder.appendingPathComponent("Loopback.bin")
        let empty=folder.appendingPathComponent("Empty.txt")
        try content.write(to:first);try Data().write(to:empty)
        let delegate=LoopbackDelegate(expectation:done,expected:["Loopback.bin":content,"Empty.txt":Data()])
        let listener=try NWListener(using:.tcp)
        listener.newConnectionHandler = {conn in
            print("Loopback: TCP receiver connected")
            let receiver=InboundNearbyConnection(connection:conn,id:"test-incoming")
            delegate.receiver=receiver;receiver.delegate=delegate;receiver.start()
        }
        listener.stateUpdateHandler = {state in
            if case .ready=state, let port=listener.port {
                print("Loopback: listener ready")
                let conn=NWConnection(host:"127.0.0.1",port:port,using:.tcp)
                let sender=OutboundNearbyConnection(connection:conn,id:"test-outgoing",urlsToSend:[first,empty])
                delegate.sender=sender;sender.delegate=delegate;sender.start()
            }
        }
        listener.start(queue:.main)
        // Debug P-256 arithmetic and simulator scheduling vary significantly on hosted runners.
        wait(for:[done],timeout:90)
        listener.cancel()
        delegate.sender=nil;delegate.receiver=nil
    }
}

import Network
private final class LoopbackDelegate:InboundNearbyConnectionDelegate,OutboundNearbyConnectionDelegate {
    let expectation:XCTestExpectation
    let expected:[String:Data]
    var sender:OutboundNearbyConnection?
    var receiver:InboundNearbyConnection?
    init(expectation:XCTestExpectation,expected:[String:Data]) {self.expectation=expectation;self.expected=expected}
    func obtainUserConsent(for transfer:TransferMetadata,from device:RemoteDeviceInfo,connection:InboundNearbyConnection) {
        print("Loopback: consent requested; handshake completed")
        XCTAssertEqual(connection.pinCode,sender?.pinCode)
        XCTAssertEqual(transfer.files.count,2)
        connection.submitUserConsent(accepted:true)
    }
    func receivedFile(url:URL,connection:InboundNearbyConnection) {
        print("Loopback: received fixture \(url.lastPathComponent)")
        XCTAssertEqual(try? Data(contentsOf:url),expected[url.lastPathComponent])
        try? FileManager.default.removeItem(at:url)
        expectation.fulfill()
    }
    func incomingProgress(connection:InboundNearbyConnection,progress:Double) {}
    func connectionWasTerminated(connection:InboundNearbyConnection,error:Error?) {XCTAssertNil(error)}
    func outboundConnectionWasEstablished(connection:OutboundNearbyConnection) {print("Loopback: encryption established")}
    func outboundConnectionTransferAccepted(connection:OutboundNearbyConnection) {print("Loopback: receiver accepted")}
    func outboundConnection(connection:OutboundNearbyConnection,transferProgress:Double) {}
    func outboundConnection(connection:OutboundNearbyConnection,failedWithError:Error) {XCTFail("Encrypted transfer failed: \(failedWithError)")}
    func outboundConnectionTransferFinished(connection:OutboundNearbyConnection) {print("Loopback: sender finished");expectation.fulfill()}
}

final class DiscoveryRegressionTests:XCTestCase {
    func testQuickShareBeaconDoesNotMatchOrdinaryFastPairAccessories() {
        XCTAssertTrue(BluetoothDiscovery.isQuickShareHint(Data([0xfc,0x12,0x8e,0,66])))
        XCTAssertFalse(BluetoothDiscovery.isQuickShareHint(Data([1,2,3,0,66])))
        XCTAssertFalse(BluetoothDiscovery.isQuickShareHint(Data([0xfc,0x12,0x8e])))
        XCTAssertFalse(BluetoothDiscovery.isQuickShareHint(Data([0xfc,0x12,0x8e,0xe0,66])))
    }
    func testBuiltAppDeclaresBluetoothAndExactBonjourService() {
        let info=Bundle.main.infoDictionary ?? [:]
        XCTAssertFalse((info["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertFalse((info["NSLocalNetworkUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertTrue((info["NSBonjourServices"] as? [String] ?? []).contains("_FC9F5ED42C8A._tcp"))
    }
    func testBlockedLocalNetworkShowsRecoveryInstruction() {
        let message=NearbyConnectionManager.networkIssue(.dns(-65570))
        XCTAssertTrue(message.contains("Lokales Netzwerk"))
        XCTAssertTrue(message.contains("Einstellungen"))
    }
    func testVisibilityWaitsForBonjourRegistrationAndCanRestart() {
        let manager=NearbyConnectionManager.shared
        for _ in 0..<2 {
            let registered=expectation(description:"Bonjour service registered")
            var fulfilled=false
            manager.visibilityStatusHandler = {visible,_ in
                if visible && !fulfilled {fulfilled=true;registered.fulfill()}
            }
            manager.becomeVisible()
            wait(for:[registered],timeout:15)
            manager.becomeHidden()
        }
        manager.visibilityStatusHandler=nil
    }
}
