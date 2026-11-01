import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum SafeFileName {
    static func validate(_ name:String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: {CharacterSet.controlCharacters.contains($0)}) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return name
    }
}
enum StoragePaths {
    static let groupID="group.eu.simplexsmp.dropquick"
    static var base:URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:groupID)
        ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    }
    static var received:URL {directory("Received")}
    static var outbox:URL {directory("Outbox")}
    static var staging:URL {directory("Staging")}
    static func directory(_ name:String)->URL {
        let url=base.appendingPathComponent(name,isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    static func importFile(_ url:URL, to folder:URL?=nil)throws->URL {
        let access=url.startAccessingSecurityScopedResource()
        defer {if access {url.stopAccessingSecurityScopedResource()}}
        let values=try url.resourceValues(forKeys:[.isRegularFileKey])
        guard values.isRegularFile == true else {throw CocoaError(.fileReadUnsupportedScheme)}
        let name=try SafeFileName.validate(url.lastPathComponent)
        let dir=(folder ?? outbox).appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let dest=dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at:url,to:dest)
        return dest
    }
}
enum DeviceIdentity {
    static var name:String {UserDefaults.standard.string(forKey:"deviceName") ?? "DropQuick iPhone"}
}
struct TransferRecord:Identifiable,Codable {
    var id=UUID()
    var date=Date()
    var direction:String
    var peer:String
    var names:[String]
    var paths:[String]
    var state:String
    var detail:String?
}
enum HistoryStore {
    static var url:URL {StoragePaths.base.appendingPathComponent("history.json")}
    static func read()->[TransferRecord] {
        guard let data=try? Data(contentsOf:url) else {return []}
        return (try? JSONDecoder().decode([TransferRecord].self,from:data)) ?? []
    }
    static func save(_ records:[TransferRecord])throws {
        try JSONEncoder().encode(Array(records.prefix(500))).write(to:url,options:.atomic)
    }
}
