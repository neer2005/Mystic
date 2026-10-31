use serde_json::{json,Value};
use std::{ffi::{c_char,CStr},net::{Ipv4Addr,ToSocketAddrs,UdpSocket}};

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
#[no_mangle]
pub unsafe extern "C" fn mystic_wake(request:*const c_char) -> *mut c_char {
    crate::host::envelope((|| {
        if request.is_null() { return Err("Missing wake request.".into()); }
        let bytes=CStr::from_ptr(request).to_bytes();
        if bytes.len() > 8192 { return Err("Wake request is too large.".into()); }
        let v:Value=serde_json::from_slice(bytes).map_err(|_|"Invalid wake request.")?;
        let host=v["host"].as_str().filter(|s|!s.is_empty() && s.len() <= 253).ok_or("Missing saved host address.")?;
        let packets:Vec<_>=v["macs"].as_array().ok_or("No wake addresses saved.")?.iter().take(8).filter_map(|m|m.as_str().and_then(|m|magic(m).ok())).collect();
        if packets.is_empty() { return Err("Connect to this PC once to remember a usable Wake-on-LAN address.".into()); }
        let mut targets=vec![Ipv4Addr::BROADCAST];
        if let Some(b)=v["broadcasts"].as_array() {
            for ip in b.iter().take(16).filter_map(|x|x.as_str()?.parse::<Ipv4Addr>().ok()) {
                if !ip.is_unspecified() && !ip.is_multicast() && !ip.is_loopback() && !targets.contains(&ip) { targets.push(ip); }
            }
        }
        let socket=UdpSocket::bind("0.0.0.0:0").map_err(|e|e.to_string())?;
        socket.set_broadcast(true).map_err(|e|e.to_string())?;
        let mut destinations:Vec<_>=targets.into_iter().map(|ip|std::net::SocketAddr::from((ip,9))).collect();
        if let Ok(addresses)=(host,9).to_socket_addrs() { destinations.extend(addresses.filter(|a|a.is_ipv4()).take(4)); }
        destinations.sort();destinations.dedup();
        let mut sent=0;
        for packet in packets { for target in &destinations { if socket.send_to(&packet,target).is_ok() { sent+=1; } } }
        if sent == 0 { return Err("No wake packets could be sent. Check the Mac's network connection.".into()); }
        Ok(json!({"sent":sent}))
    })())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn magic_packet_has_six_ff_and_sixteen_physical_addresses() {
        let packet=magic("02:7c:16:b4:13:4f").unwrap();
        assert_eq!(&packet[..6],&[255;6]);
        for chunk in packet[6..].chunks_exact(6) { assert_eq!(chunk,&[2,124,22,180,19,79]); }
        for bad in ["", "00:00:00:00:00:00","ff:ff:ff:ff:ff:ff","03:00:00:00:00:01","02:zz:00:00:00:01"] { assert!(magic(bad).is_err()); }
    }
}
