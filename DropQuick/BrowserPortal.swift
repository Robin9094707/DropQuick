import Foundation
import Network
import Darwin

/// Explicit, short-lived LAN browser fallback. This is not Windows MS-CDP/NearShare.
/// HTTP is intentionally local-only; the UI explains that this mode is unencrypted.
final class BrowserPortal {
    var onReceived:((URL)->Void)?
    var onDownloaded:((URL)->Void)?
    var onError:((String)->Void)?
    private var listener:NWListener?
    private var connections:[UUID:NWConnection]=[:]
    private var expiry:DispatchWorkItem?
    private var files:[URL]=[]
    private var token=""
    private let queue=DispatchQueue(label:"DropQuick.browser",qos:.utility)
    static let maxUpload=50*1024*1024
    static let maxHeader=16*1024
    func start(files:[URL],ready:@escaping(String)->Void)throws {
        stop()
        guard let ip=Self.localIPv4() else {throw CocoaError(.fileNoSuchFile)}
        self.files=files
        token=UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let listener=try NWListener(using:.tcp)
        self.listener=listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready=state, let port=listener?.port, let self=self {
                ready("http://\(ip):\(port.rawValue)/\(self.token)/")
            } else if case .failed(let error)=state {self?.onError?(error.localizedDescription)}
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self=self, self.connections.count < 8 else {conn.cancel();return}
            let id=UUID(); self.connections[id]=conn
            conn.start(queue:self.queue)
            self.receive(conn,id:id,buffer:Data())
        }
        listener.start(queue:queue)
        let task=DispatchWorkItem { [weak self] in self?.stop() }
        expiry=task; queue.asyncAfter(deadline:.now()+600,execute:task)
    }
    func stop() {
        expiry?.cancel(); expiry=nil
        listener?.cancel(); listener=nil
        queue.async { [weak self] in
            guard let self=self else {return}
            for conn in self.connections.values {conn.cancel()}
            self.connections.removeAll()
        }
    }
    private func close(_ conn:NWConnection,id:UUID) {conn.cancel();connections.removeValue(forKey:id)}
    private func receive(_ conn:NWConnection,id:UUID,buffer:Data) {
        conn.receive(minimumIncompleteLength:1,maximumLength:64*1024) { [weak self] data,_,done,error in
            guard let self=self else {return}
            if error != nil || (done && data?.isEmpty != false) {self.close(conn,id:id);return}
            var buffer=buffer
            if let data=data {buffer.append(data)}
            guard buffer.count<=Self.maxUpload+Self.maxHeader else {self.respond(conn,id:id,status:"413 Payload Too Large",body:Data());return}
            guard let range=buffer.range(of:Data("\r\n\r\n".utf8)) else {
                guard buffer.count<Self.maxHeader else {self.close(conn,id:id);return}
                self.receive(conn,id:id,buffer:buffer);return
            }
            guard range.upperBound <= Self.maxHeader,
                  let header=String(data:buffer[..<range.lowerBound],encoding:.utf8),
                  let line=header.components(separatedBy:"\r\n").first else {self.close(conn,id:id);return}
            let parts=line.split(separator:" ")
            guard parts.count==3 else {self.close(conn,id:id);return}
            let method=String(parts[0]); let path=String(parts[1])
            guard path.hasPrefix("/\(self.token)/") else {self.respond(conn,id:id,status:"404 Not Found",body:Data());return}
            let fields=header.components(separatedBy:"\r\n").dropFirst()
            var length=0
            var contentLengths=0
            for field in fields {
                let pair=field.split(separator:":",maxSplits:1)
                if pair.first?.lowercased()=="content-length" {
                    contentLengths+=1
                    guard pair.count==2, let value=Int(pair[1].trimmingCharacters(in:.whitespaces)),value>=0,value<=Self.maxUpload else {self.close(conn,id:id);return}
                    length=value
                }
                if pair.first?.lowercased()=="transfer-encoding" {self.close(conn,id:id);return}
            }
            guard contentLengths<=1 else {self.close(conn,id:id);return}
            let body=buffer.subdata(in:range.upperBound..<buffer.count)
            if body.count<length {self.receive(conn,id:id,buffer:buffer);return}
            if method=="GET" && path=="/\(self.token)/" {
                self.respond(conn,id:id,status:"200 OK",type:"text/html; charset=utf-8",body:Data(self.page().utf8))
            } else if method=="GET", let index=Int(path.components(separatedBy:"/").last ?? ""),self.files.indices.contains(index) {
                self.sendFile(self.files[index],conn:conn,id:id)
            } else if method=="POST",path.hasPrefix("/\(self.token)/upload?name="),contentLengths==1 {
                let raw=String(path.dropFirst("/\(self.token)/upload?name=".count))
                do {
                    let name=try SafeFileName.validate(raw.removingPercentEncoding ?? "")
                    let folder=StoragePaths.received.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    let dest=folder.appendingPathComponent(name)
                    try body.prefix(length).write(to:dest,options:.atomic)
                    self.onReceived?(dest)
                    self.respond(conn,id:id,status:"200 OK",body:Data("Empfangen".utf8))
                } catch {self.respond(conn,id:id,status:"400 Bad Request",body:Data("Ungültige Datei".utf8))}
            } else {self.respond(conn,id:id,status:"404 Not Found",body:Data())}
        }
        queue.asyncAfter(deadline:.now()+30) { [weak self, weak conn] in
            guard let self=self, let conn=conn, self.connections[id] != nil else {return}
            self.close(conn,id:id)
        }
    }
    private func respond(_ conn:NWConnection,id:UUID,status:String,type:String="text/plain; charset=utf-8",body:Data) {
        let headers="HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'\r\n\r\n"
        conn.send(content:Data(headers.utf8)+body,completion:.contentProcessed { [weak self] _ in self?.close(conn,id:id) })
    }
    private func sendFile(_ url:URL,conn:NWConnection,id:UUID) {
        do {
            let handle=try FileHandle(forReadingFrom:url)
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            let encoded=url.lastPathComponent.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? "file"
            let header="HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=UTF-8''\(encoded)\r\nContent-Length: \(size)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            conn.send(content:Data(header.utf8),completion:.contentProcessed { [weak self] error in
                if error != nil {try? handle.close(); self?.close(conn,id:id);return}
                self?.stream(handle,url:url,conn:conn,id:id)
            })
        } catch {respond(conn,id:id,status:"404 Not Found",body:Data())}
    }
    private func stream(_ handle:FileHandle,url:URL,conn:NWConnection,id:UUID) {
        do {
            guard let chunk=try handle.read(upToCount:256*1024), !chunk.isEmpty else {
                try? handle.close();onDownloaded?(url);close(conn,id:id);return
            }
            conn.send(content:chunk,completion:.contentProcessed { [weak self] error in
                guard error==nil else {try? handle.close();self?.close(conn,id:id);return}
                self?.stream(handle,url:url,conn:conn,id:id)
            })
        } catch {try? handle.close();close(conn,id:id)}
    }
    private func page()->String {
        let rows=files.enumerated().map {index,url in
            "<a download href='./file/\(index)'>↓ \(Self.escape(url.lastPathComponent))</a>"
        }.joined()
        return """
        <!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>DropQuick</title>
        <style>body{font:17px system-ui;background:#101526;color:#f1f4ff;max-width:600px;margin:50px auto;padding:24px}h1{font-size:42px}a,button{display:block;background:#c3f36b;color:#162510;padding:18px;border-radius:18px;margin:12px 0;text-decoration:none;border:0;font:inherit}section{background:#ffffff0d;padding:24px;border-radius:26px}small{color:#b2bdd0}input{max-width:100%}</style>
        <h1>DropQuick ↗</h1><p>Direkt zwischen deinen Geräten.</p><section><h2>Dateien laden</h2>\(rows.isEmpty ? "Keine Dateien ausgewählt." : rows)</section>
        <section><h2>Zum iPhone senden</h2><input type="file" id="file" multiple><button id="send">Dateien senden</button><p id="status"></p></section>
        <p><small>Gleiches WLAN • Nur solange DropQuick offen ist • Max. 50 MB pro Upload • Diese lokale HTTP-Verbindung ist nicht verschlüsselt. Jeder mit diesem Link kann Dateien laden und hochladen.</small></p>
        <script>document.getElementById('send').onclick=async()=>{const s=document.getElementById('status');for(const f of document.getElementById('file').files){if(f.size>52428800){s.textContent='Datei zu groß (max. 50 MB)';return;}s.textContent='Sende '+f.name;try{const r=await fetch('./upload?name='+encodeURIComponent(f.name),{method:'POST',body:f});if(!r.ok)throw Error('HTTP '+r.status);s.textContent='Empfangen: '+f.name;}catch(e){s.textContent='Fehler: '+e.message;return;}}};</script></html>
        """
    }
    static func escape(_ text:String)->String {text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
    static func localIPv4()->String? {
        var list:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list)==0 else {return nil}
        defer {freeifaddrs(list)}
        var cursor=list
        while let item=cursor {
            let info=item.pointee
            defer {cursor=info.ifa_next}
            guard let addr=info.ifa_addr,addr.pointee.sa_family==UInt8(AF_INET),String(cString:info.ifa_name)=="en0" else {continue}
            var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0 {return String(cString:host)}
        }
        return nil
    }
}
