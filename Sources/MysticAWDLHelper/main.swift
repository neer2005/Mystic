import Darwin
import Foundation
import MysticCore
import Security

// Runs as root, only while Mystic holds a connection, and can do one thing: hold awdl0 down or
// let it up. macOS brings the interface back whenever it likes, so the route socket says when
// to look again.

private let SIOCGIFFLAGS: UInt=0xc0206911 // _IOWR('i',17,struct ifreq)
private let SIOCSIFFLAGS: UInt=0x80206910 // _IOW('i',16,struct ifreq)

final class AWDLMonitor: @unchecked Sendable {
    private let queue=DispatchQueue(label:"mystic.awdl",qos:.userInitiated)
    private let flagsSocket=socket(AF_INET,SOCK_DGRAM,0)
    private let routeSocket=socket(AF_ROUTE,SOCK_RAW,0)
    private var source: (any DispatchSourceRead)?
    private var held=false
    init?() {
        guard flagsSocket >= 0,routeSocket >= 0,fcntl(routeSocket,F_SETFL,O_NONBLOCK) == 0 else { return nil }
        let source=DispatchSource.makeReadSource(fileDescriptor:routeSocket,queue:queue)
        source.setEventHandler { [self] in
            var buffer=[UInt8](repeating:0,count:2048)
            while read(routeSocket,&buffer,buffer.count) > 0 {}
            apply()
        }
        source.resume()
        self.source=source
    }
    func set(held: Bool) { queue.sync { self.held=held;apply() } }
    private func apply() {
        var request=ifreq()
        withUnsafeMutableBytes(of:&request.ifr_name) { bytes in
            AWDLHold.interface.utf8CString.withUnsafeBytes { bytes.copyBytes(from:$0) }
        }
        guard ioctl(flagsSocket,SIOCGIFFLAGS,&request) == 0 else { return }
        guard let flags=AWDLHold.flags(current:Int32(request.ifr_ifru.ifru_flags),held:held) else { return }
        request.ifr_ifru.ifru_flags=Int16(truncatingIfNeeded:flags)
        if ioctl(flagsSocket,SIOCSIFFLAGS,&request) != 0 { NSLog("Mystic AWDL helper: could not set awdl0: %d",errno) }
    }
}

final class HelperService: NSObject,NSXPCListenerDelegate,AWDLHelperProtocol,@unchecked Sendable {
    private let monitor: AWDLMonitor
    private let lock=NSLock()
    private var clients=0
    init(monitor: AWDLMonitor) { self.monitor=monitor }
    func setHeld(_ held: Bool) { monitor.set(held:held) }
    func listener(_ listener: NSXPCListener,shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface=NSXPCInterface(with:AWDLHelperProtocol.self)
        connection.exportedObject=self
        lock.withLock { clients+=1 }
        connection.invalidationHandler={ [self] in
            let last=lock.withLock { clients-=1;return clients == 0 }
            guard last else { return }
            // Mystic quit or crashed, or finished: AirDrop comes back, and nothing stays running.
            monitor.set(held:false)
            exit(0)
        }
        connection.resume()
        return true
    }
}

/// This helper's own team, so it trusts only an app signed by the same developer.
func signingTeam() -> String? {
    var code: SecCode?,staticCode: SecStaticCode?,information: CFDictionary?
    guard SecCodeCopySelf([],&code) == errSecSuccess,let code,
          SecCodeCopyStaticCode(code,[],&staticCode) == errSecSuccess,let staticCode,
          SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information) == errSecSuccess
    else { return nil }
    return (information as? [String:Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}

guard let team=signingTeam(),let monitor=AWDLMonitor() else {
    NSLog("Mystic AWDL helper: not signed by a team, or no sockets; refusing to start")
    exit(1)
}
let service=HelperService(monitor:monitor)
let listener=NSXPCListener(machServiceName:AWDLHold.helperLabel)
listener.setConnectionCodeSigningRequirement(AWDLHold.clientRequirement(team:team))
listener.delegate=service
listener.resume()
RunLoop.main.run()
