/// The stream's per-second figures for a CSV, in the columns of Nightjar's desktop "Save
/// statistics" (`elapsed_ms` to `bitrate_kbps`), the last hour kept. Columns Mystic does not
/// measure (the host's present-to-network time, glass-to-glass latency) stay empty, as Nightjar
/// leaves an unmeasured column.
public struct StreamStatistics: Sendable, Equatable {
    public static let header="elapsed_ms,received_fps,decoded_fps,shown_fps,loss_percent,rtt_ms,decode_ms,render_ms,host_to_network_ms,latency_ms,bitrate_kbps\n"
    public static let maxRows=3600
    public struct Row: Sendable, Equatable {
        public var elapsedMs: UInt64
        public var receivedFps,decodedFps,shownFps,lossPercent: Double?
        public var rttMs,decodeMs,renderMs: Double?
        public var bitrateKbps: UInt32
        public init(elapsedMs: UInt64,receivedFps: Double?,decodedFps: Double?,shownFps: Double?,lossPercent: Double?,
                    rttMs: Double?,decodeMs: Double?,renderMs: Double?,bitrateKbps: UInt32) {
            self.elapsedMs=elapsedMs;self.receivedFps=receivedFps;self.decodedFps=decodedFps;self.shownFps=shownFps
            self.lossPercent=lossPercent;self.rttMs=rttMs;self.decodeMs=decodeMs;self.renderMs=renderMs;self.bitrateKbps=bitrateKbps
        }
        var line: String {
            func v(_ value: Double?,zero: Bool = false) -> String {
                guard let value,value.isFinite else { return zero ? "0.000" : "" }
                return String(format:"%.3f",value)
            }
            // As Nightjar: rates and loss read 0 when nothing arrived; timings stay empty.
            return [String(elapsedMs),v(receivedFps,zero:true),v(decodedFps,zero:true),v(shownFps,zero:true),v(lossPercent,zero:true),
                    v(rttMs),v(decodeMs),v(renderMs),"","",String(bitrateKbps)].joined(separator:",")+"\n"
        }
    }
    public private(set) var rows: [Row]=[]
    public init() {}
    public mutating func add(_ row: Row) {
        rows.append(row)
        if rows.count > Self.maxRows { rows.removeFirst(rows.count-Self.maxRows) }
    }
    public var csv: String { Self.header+rows.map(\.line).joined() }
}
