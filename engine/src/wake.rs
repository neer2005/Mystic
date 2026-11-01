//! Wake-on-LAN as Nightjar's desktop client sends it (`wol.rs`): every saved MAC, to the PC's
//! addresses, 255.255.255.255 and the subnet broadcasts of this Mac and of the PC, on the
//! classic and Moonlight ports, three times over; and to `ff02::1` on each IPv6 link, best effort.
use serde_json::{json,Value};
use std::collections::BTreeSet;
use std::{ffi::{c_char,CStr},io,net::{IpAddr,Ipv4Addr,Ipv6Addr,SocketAddr,SocketAddrV6,ToSocketAddrs,UdpSocket}};

/// A host lists one target per physical adapter; more than this is not a PC's worth.
const MAX_MACS: usize = 8;
const MAX_BROADCASTS: usize = 16;

pub(crate) fn magic(mac:&str) -> Result<[u8;102],String> {
    let normalized=mac.replace('-',":");
    let parts:Vec<_>=normalized.split(':').collect();
    if parts.len() != 6 || parts.iter().any(|p|p.len() != 2) { return Err("Invalid Wake-on-LAN address.".into()); }
    let mut bytes=[0u8;6];
    for (i,p) in parts.iter().enumerate() { bytes[i]=u8::from_str_radix(p,16).map_err(|_|"Invalid Wake-on-LAN address.")?; }
    if bytes == [0;6] || bytes[0] & 1 != 0 { return Err("No usable physical Wake-on-LAN address is saved.".into()); }
    let mut packet=[255;102];
    for copy in packet[6..].chunks_exact_mut(6) { copy.copy_from_slice(&bytes); }
    Ok(packet)
}

/// Echo and discard, where magic packets classically go, the port Moonlight hosts listen on,
/// and the Moonlight ports that follow `http_port`.
fn ports(http_port: u16) -> Vec<u16> {
    let http_port = if http_port == 0 { 47989 } else { http_port };
    let mut ports = vec![7, 9, 47009];
    ports.extend([9, 10, 11, 13, 21].into_iter().filter_map(|offset| http_port.checked_add(offset)));
    ports.sort_unstable();
    ports.dedup();
    ports
}

/// What one wake sends: each payload (one per MAC) to every destination, and to the best-effort ones.
struct Plan {
    payloads: Vec<[u8;102]>,
    destinations: BTreeSet<SocketAddr>,
    /// `ff02::1` on each IPv6 link; sends there may all fail without failing the wake.
    best_effort: BTreeSet<SocketAddr>,
}

fn broadcasts(list: &Value) -> impl Iterator<Item=Ipv4Addr> + '_ {
    list.as_array().into_iter().flatten().take(MAX_BROADCASTS).filter_map(|x| x.as_str()?.parse::<Ipv4Addr>().ok())
        .filter(|ip| !ip.is_unspecified() && !ip.is_multicast() && !ip.is_loopback())
}

/// `resolve` looks up the PC's address (it may block on DNS).
fn plan(v: &Value, resolve: impl Fn(&str) -> io::Result<Vec<IpAddr>>) -> Result<Plan,String> {
    let host=v["host"].as_str().filter(|s|!s.is_empty() && s.len() <= 253).ok_or("Missing saved host address.")?;
    let mut payloads=Vec::new();
    for packet in v["macs"].as_array().ok_or("No wake addresses saved.")?.iter().take(MAX_MACS).filter_map(|m|m.as_str().and_then(|m|magic(m).ok())) {
        if !payloads.contains(&packet) { payloads.push(packet); }
    }
    if payloads.is_empty() { return Err("Connect to this PC once to remember a usable Wake-on-LAN address.".into()); }
    let ports=ports(v["port"].as_u64().and_then(|p| u16::try_from(p).ok()).unwrap_or(0));
    let mut addresses=BTreeSet::from([IpAddr::V4(Ipv4Addr::BROADCAST)]);
    // Directed broadcasts reach each subnet and avoid stale ARP entries for sleeping PCs.
    addresses.extend(broadcasts(&v["localBroadcasts"]).map(IpAddr::V4));
    addresses.extend(broadcasts(&v["broadcasts"]).map(IpAddr::V4));
    // Without the PC's address, the broadcasts still get their packets.
    if let Ok(resolved)=resolve(host) { addresses.extend(resolved.into_iter().take(8)); }
    let destinations=addresses.iter().flat_map(|a| ports.iter().map(|p| SocketAddr::new(*a,*p))).collect();
    let all_nodes=Ipv6Addr::new(0xff02,0,0,0,0,0,0,1);
    let best_effort=v["ipv6Scopes"].as_array().into_iter().flatten().take(MAX_BROADCASTS)
        .filter_map(|s| s.as_u64().and_then(|s| u32::try_from(s).ok())).filter(|s| *s != 0)
        .flat_map(|scope| ports.iter().map(move |p| SocketAddr::V6(SocketAddrV6::new(all_nodes,*p,0,scope))))
        .collect();
    Ok(Plan{payloads,destinations,best_effort})
}

/// Sends the plan through `send`; the count of packets that reached a destination that is not
/// best effort. Fails only when there were none.
fn send(plan: &Plan, mut send: impl FnMut(&[u8],SocketAddr) -> io::Result<()>) -> Result<usize,String> {
    let mut sent=0;
    let mut error=String::from("No wake packets could be sent. Check the Mac's network connection.");
    // A magic packet has no acknowledgement; a short burst tolerates an isolated UDP loss.
    for _ in 0..3 {
        for payload in &plan.payloads {
            for destination in &plan.destinations {
                match send(payload,*destination) { Ok(())=>sent+=1, Err(e)=>error=format!("No wake packets could be sent: {e}") }
            }
            for destination in &plan.best_effort { let _=send(payload,*destination); }
        }
    }
    if sent == 0 { Err(error) } else { Ok(sent) }
}

#[no_mangle]
pub unsafe extern "C" fn mystic_wake(request:*const c_char) -> *mut c_char {
    crate::host::envelope((|| {
        if request.is_null() { return Err("Missing wake request.".into()); }
        let bytes=CStr::from_ptr(request).to_bytes();
        if bytes.len() > 8192 { return Err("Wake request is too large.".into()); }
        let v:Value=serde_json::from_slice(bytes).map_err(|_|"Invalid wake request.")?;
        let plan=plan(&v,|host| (host,9).to_socket_addrs().map(|a| a.map(|a| a.ip()).collect()))?;
        let socket=UdpSocket::bind("0.0.0.0:0").map_err(|e|e.to_string())?;
        socket.set_broadcast(true).map_err(|e|e.to_string())?;
        let ipv6=UdpSocket::bind("[::]:0").ok();
        let sent=send(&plan,|payload,destination| {
            let socket=if destination.is_ipv4() { &socket } else {
                ipv6.as_ref().ok_or_else(|| io::Error::new(io::ErrorKind::Unsupported,"no IPv6 socket"))?
            };
            socket.send_to(payload,destination).map(|_|())
        })?;
        Ok(json!({"sent":sent}))
    })())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn magic_packet_has_six_ff_and_sixteen_physical_addresses() {
        let packet=magic("02:7c:16:b4:13:4f").unwrap();
        assert!(packet[..6].iter().all(|b|*b == 255));
        assert!(packet[6..].chunks(6).all(|c|c == [2,0x7c,0x16,0xb4,0x13,0x4f]));
        for bad in ["", "00:00:00:00:00:00","ff:ff:ff:ff:ff:ff","03:00:00:00:00:01","02:zz:00:00:00:01"] { assert!(magic(bad).is_err()); }
    }
    #[test]
    fn ports_are_the_classic_ones_and_those_after_the_http_port() {
        assert_eq!(ports(0), vec![7, 9, 47009, 47998, 47999, 48000, 48002, 48010]);
        assert_eq!(ports(50000), vec![7, 9, 47009, 50009, 50010, 50011, 50013, 50021]);
        assert_eq!(ports(65530), vec![7, 9, 47009], "ports past 65535 are left out");
    }
    #[test]
    fn the_plan_covers_every_mac_address_broadcast_and_ipv6_link() {
        let v=json!({"host":"pc.local","port":47989,"macs":["02:7c:16:b4:13:4f","02-7C-16-B4-13-4F","02:00:00:00:00:02","bad"],
            "broadcasts":["192.168.1.255","224.0.0.1"],"localBroadcasts":["10.0.0.255","127.0.0.1"],"ipv6Scopes":[4,0]});
        let pc: IpAddr="fd7a::1".parse().unwrap();
        let plan=plan(&v,|_| Ok(vec![pc])).unwrap();
        assert_eq!(plan.payloads.len(),2,"one payload per distinct MAC");
        let addresses: BTreeSet<IpAddr>=plan.destinations.iter().map(|d| d.ip()).collect();
        let expected: BTreeSet<IpAddr>=["255.255.255.255","10.0.0.255","192.168.1.255","fd7a::1"].iter().map(|a| a.parse().unwrap()).collect();
        assert_eq!(addresses,expected);
        assert_eq!(plan.destinations.len(),4*8);
        assert_eq!(plan.best_effort.len(),8);
        assert!(plan.best_effort.iter().all(|d| matches!(d,SocketAddr::V6(v6) if v6.scope_id() == 4 && v6.ip().segments()[0] == 0xff02)));
        // An unresolvable PC still gets its broadcasts.
        let offline=super::plan(&v,|_| Err(io::Error::other("no DNS"))).unwrap();
        assert_eq!(offline.destinations.len(),3*8);
        assert!(super::plan(&json!({"host":"pc","macs":["bad"]}),|_| Ok(vec![])).is_err());
        assert!(super::plan(&json!({"macs":["02:7c:16:b4:13:4f"]}),|_| Ok(vec![])).is_err());
    }
    #[test]
    fn three_bursts_and_ipv6_failures_do_not_fail_the_wake() {
        let v=json!({"host":"pc","macs":["02:7c:16:b4:13:4f"],"ipv6Scopes":[3]});
        let plan=plan(&v,|_| Ok(vec![])).unwrap();
        let mut sends=0;
        let sent=send(&plan,|_,d| { sends+=1; if d.is_ipv6() { Err(io::Error::other("unreachable")) } else { Ok(()) } }).unwrap();
        assert_eq!(sent,3*8,"255.255.255.255 on eight ports, three times");
        assert_eq!(sends,3*16);
        assert!(send(&plan,|_,_| Err(io::Error::other("down"))).unwrap_err().contains("down"));
    }
}
