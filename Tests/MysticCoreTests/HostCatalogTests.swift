import Testing
import Foundation
@testable import MysticCore

struct HostCatalogTests {
    @Test func endpointNormalizationAndValidation() throws {
        let host=try #require(HostEndpoint(address:"  PC.Local  ",port:47989))
        #expect(host.id == "pc.local:47989")
        #expect(HostEndpoint(address:"100.66.0.33",port:48000)?.port == 48000)
        #expect(HostEndpoint(address:"fe80::1%en0",port:47989) != nil)
        for address in ["","https://pc","pc/path","pc:47989","pc name","pc\0evil","pc?x","user@pc","[::1]"] {
            #expect(HostEndpoint(address:address,port:47989) == nil)
        }
        #expect(HostEndpoint(address:"pc",port:0) == nil)
    }
    @Test func boundedCatalogUpdatesExactEndpointsAndRoundTrips() throws {
        var catalog=HostCatalog()
        for n in 0..<40 {
            let endpoint=try #require(HostEndpoint(address:"pc\(n).local",port:47989))
            catalog.remember(endpoint:endpoint,name:"Host \(n)",uniqueID:"id\(n)",at:Date(timeIntervalSince1970:Double(n)))
        }
        #expect(catalog.hosts.count == 32)
        #expect(catalog.hosts.first?.name == "Host 39")
        #expect(catalog.hosts.last?.name == "Host 8")
        let first=try #require(catalog.hosts.first)
        catalog.remember(endpoint:first.endpoint,name:"Renamed",uniqueID:"id39",at:Date(timeIntervalSince1970:100))
        #expect(catalog.hosts.count == 32)
        let decoded=try HostCatalog(data:catalog.encoded())
        #expect(decoded.hosts == catalog.hosts)
        let other=try #require(HostEndpoint(address:first.endpoint.address,port:48000))
        catalog.remember(endpoint:other,name:"Renamed",uniqueID:"id39")
        #expect(catalog.hosts[1].endpoint == first.endpoint) // Never merge on name or host ID.
        catalog.remove(other)
        #expect(catalog.hosts.first?.endpoint == first.endpoint)
    }
    @Test func malformedPreferencesAreRejected() throws {
        for json in ["{}","{\"version\":2,\"hosts\":[]}","{\"version\":1,\"hosts\":[{\"endpoint\":{\"address\":\"https://bad\",\"port\":47989},\"name\":\"bad\"}]}"] {
            #expect(throws:(any Error).self) { try HostCatalog(data:Data(json.utf8)) }
        }
        #expect(throws:(any Error).self) { try HostCatalog(data:Data(repeating:0,count:1_048_577)) }
        let endpoint=try #require(HostEndpoint(address:"pc.local",port:47989))
        var catalog=HostCatalog()
        catalog.remember(endpoint:endpoint,name:" ",uniqueID:nil,at:nil)
        #expect(catalog.hosts.first?.name == "pc.local")
        #expect(catalog.hosts.first?.lastConnected == nil)
    }
}
