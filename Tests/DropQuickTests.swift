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
