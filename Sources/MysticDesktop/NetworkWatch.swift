import Foundation
import Network
import Darwin

/// What the network watcher saw toward the host.
enum LinkEvent: Equatable, Sendable {
    /// The route toward the host went away: the stream cannot reach it.
    case lost
    /// A different network, or one back after the route was gone (`afterLoss`).
    case changed(metered: Bool,afterLoss: Bool)
}

/// Nightjar's `LinkWatch`: one look at a time becomes the route going away once, or a change of
/// the address this Mac uses toward the host. The same address with new metering is no change.
struct LinkWatch: Sendable {
    struct Link: Equatable, Sendable {
        var local: String
        /// Bills by data: an iPhone hotspot or cellular link, or Low Data Mode.
        var metered: Bool
    }
    private var current: Link
    private var lost=false
    init(_ start: Link) { current=start }
    mutating func event(_ link: Link?) -> LinkEvent? {
        guard let link else {
            if lost { return nil }
            lost=true;return .lost
        }
        if !lost,link.local == current.local { current.metered=link.metered;return nil }
        let afterLoss=lost
        lost=false;current=link
        return .changed(metered:link.metered,afterLoss:afterLoss)
    }
}

/// The stream's network watcher, as Nightjar's desktop `RoamWatch`: looks at the route toward
/// the host once a second and on every path change, off the main thread, and hands each event
/// to `onEvent` on its own queue. It stops when told to or when released.
final class NetworkWatch: @unchecked Sendable {
    private let queue=DispatchQueue(label:"Mystic.NetworkWatch")
    private let monitor=NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var watch: LinkWatch
    private var metered=false
    private let remote: sockaddr_storage
    private let onEvent: @Sendable (LinkEvent) -> Void
    private var stopped=false

    /// Nil when there is no route toward the host now, or its address does not resolve.
    /// Resolving may block on DNS, so call it off the main actor.
    static func start(host: String,port: UInt16,onEvent: @escaping @Sendable (LinkEvent) -> Void) -> NetworkWatch? {
        guard let remote=resolve(host:host,port:port),let local=localAddress(toward:remote) else { return nil }
        let watch=NetworkWatch(remote:remote,start:LinkWatch.Link(local:local,metered:false),onEvent:onEvent)
        watch.begin();return watch
    }
    private init(remote: sockaddr_storage,start: LinkWatch.Link,onEvent: @escaping @Sendable (LinkEvent) -> Void) {
        self.remote=remote;watch=LinkWatch(start);self.onEvent=onEvent
    }
    private func begin() {
        monitor.pathUpdateHandler={ [weak self] path in
            guard let self else { return }
            self.metered=path.isExpensive || path.isConstrained
            self.look()
        }
        monitor.start(queue:queue)
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler { [weak self] in self?.look() }
        timer.resume();self.timer=timer
    }
    /// Runs on `queue`.
    private func look() {
        guard !stopped else { return }
        let link=Self.localAddress(toward:remote).map { LinkWatch.Link(local:$0,metered:metered) }
        if let event=watch.event(link) { onEvent(event) }
    }
    func stop() {
        queue.sync {
            stopped=true
            timer?.cancel();timer=nil
            monitor.cancel()
        }
    }
    deinit { timer?.cancel();monitor.cancel() }

    private static func resolve(host: String,port: UInt16) -> sockaddr_storage? {
        var hints=addrinfo()
        hints.ai_socktype=SOCK_DGRAM;hints.ai_flags=AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,String(port),&hints,&list) == 0,let first=list else { return nil }
        defer { freeaddrinfo(list) }
        var storage=sockaddr_storage()
        withUnsafeMutableBytes(of:&storage) { $0.copyMemory(from:UnsafeRawBufferPointer(start:first.pointee.ai_addr,count:Int(first.pointee.ai_addrlen))) }
        return storage
    }
    /// The local address the system routes traffic for `remote` from. Connecting a UDP socket
    /// sends nothing.
    static func localAddress(toward remote: sockaddr_storage) -> String? {
        var remote=remote
        let family=Int32(remote.ss_family)
        let length=socklen_t(family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let socket=Darwin.socket(family,SOCK_DGRAM,0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        let connected=withUnsafePointer(to:&remote) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(socket,$0,length) } }
        guard connected == 0 else { return nil }
        var local=sockaddr_storage(),localLength=socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named=withUnsafeMutablePointer(to:&local) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(socket,$0,&localLength) } }
        guard named == 0 else { return nil }
        var text=[CChar](repeating:0,count:Int(NI_MAXHOST))
        let printed=withUnsafePointer(to:&local) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) {
            getnameinfo($0,localLength,&text,socklen_t(text.count),nil,0,NI_NUMERICHOST)
        } }
        return printed == 0 ? String(decoding:text.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self) : nil
    }
}
