import AppKit
import SwiftUI
import MysticCore

/// A number that commits on Return or leaving the field, so typing "1" on the way to "120"
/// never counts as a choice.
private struct NumberField<Value: BinaryInteger & Sendable>: View {
    let title: String
    @Binding var value: Value
    var body: some View {
        TextField(title,value:$value,format:IntegerFormatStyle<Value>().grouping(.never)).multilineTextAlignment(.trailing)
    }
}

/// Native, Nightjar's sizes and Custom. The picker stays short so its indicator is never
/// squeezed; the purpose follows below.
struct ResolutionField: View {
    @Binding var resolution: String
    @State private var customChosen=false
    private static let custom="custom"
    private var isCustom: Bool {
        resolution != StreamPreferences.nativeResolution && (customChosen || !StreamPreferences.resolutions.contains(resolution))
    }
    private var selection: Binding<String> {
        Binding(get:{ isCustom ? Self.custom : resolution },set:{ choice in
            customChosen = choice == Self.custom
            guard choice == Self.custom else { resolution=choice;return }
            if StreamPreferences.size(resolution) == nil {
                // Starts from this Mac's screen, as Nightjar's does.
                var video=StreamVideoSettings();video.resolution=StreamPreferences.nativeResolution
                let mode=video.mode(displayPixels:NSScreen.main.map(DisplayRefresh.pixels),displayHertz:nil)
                resolution="\(mode.width)x\(mode.height)"
            }
        })
    }
    private func dimension(_ keep: @escaping (UInt32) -> String,_ current: UInt32,_ range: ClosedRange<UInt32>) -> Binding<UInt32> {
        Binding(get:{ current },set:{ customChosen=true;resolution=keep(min(range.upperBound,max(range.lowerBound,$0))) })
    }
    var body: some View {
        Picker("Resolution",selection:selection) {
            Text(StreamPreferences.resolutionLabel(StreamPreferences.nativeResolution)).tag(StreamPreferences.nativeResolution)
            Divider()
            ForEach(StreamPreferences.resolutions,id:\.self) { Text(StreamPreferences.resolutionLabel($0)).tag($0) }
            Divider()
            Text("Custom…").tag(Self.custom)
        }
        if isCustom,let size=StreamPreferences.size(resolution) {
            NumberField(title:"Width",value:dimension({ "\($0)x\(size.height)" },size.width,StreamPreferences.customWidths))
            NumberField(title:"Height",value:dimension({ "\(size.width)x\($0)" },size.height,StreamPreferences.customHeights))
        } else if let detail=StreamPreferences.resolutionDetail(resolution) {
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Display, Nightjar's rates and Custom.
struct FrameRateField: View {
    @Binding var fps: UInt32
    @State private var customChosen=false
    private static let custom=UInt32.max
    private var isCustom: Bool {
        fps != StreamPreferences.displayFrameRate && (customChosen || !StreamPreferences.frameRates.contains(fps))
    }
    private var selection: Binding<UInt32> {
        Binding(get:{ isCustom ? Self.custom : fps },set:{ choice in
            customChosen = choice == Self.custom
            guard choice == Self.custom else { fps=choice;return }
            if fps == StreamPreferences.displayFrameRate {
                let range=StreamPreferences.customFrameRates
                fps=min(range.upperBound,max(range.lowerBound,UInt32(NSScreen.main.map(DisplayRefresh.hertz)?.rounded() ?? 60)))
            }
        })
    }
    private var custom: Binding<UInt32> {
        Binding(get:{ fps },set:{ value in
            let range=StreamPreferences.customFrameRates
            customChosen=true;fps=min(range.upperBound,max(range.lowerBound,value))
        })
    }
    var body: some View {
        Picker("Frame Rate",selection:selection) {
            Text(StreamPreferences.frameRateLabel(StreamPreferences.displayFrameRate)).tag(StreamPreferences.displayFrameRate)
            Divider()
            ForEach(StreamPreferences.frameRates,id:\.self) { Text(StreamPreferences.frameRateLabel($0)).tag($0) }
            Divider()
            Text("Custom…").tag(Self.custom)
        }
        if isCustom { NumberField(title:"Frames per Second",value:custom) }
    }
}

/// Recommended follows the stream's size and rate; turning it off starts from what it came to.
struct BitrateField: View {
    @Binding var bitrateMbps: Int32
    /// The settled stream, to state Recommended; nil where the size is not known yet.
    let recommended: StreamMode?
    private var usesRecommended: Binding<Bool> {
        Binding(get:{ bitrateMbps == StreamPreferences.recommendedBitrate },set:{ on in
            bitrateMbps=on ? StreamPreferences.recommendedBitrate : max(StreamPreferences.bitrates.lowerBound,(recommended?.bitrateKbps ?? 20_000)/1000)
        })
    }
    private var chosen: Binding<Int32> {
        Binding(get:{ bitrateMbps },set:{ value in
            let range=StreamPreferences.bitrates
            bitrateMbps=min(range.upperBound,max(range.lowerBound,value))
        })
    }
    var body: some View {
        Toggle("Recommended Bitrate",isOn:usesRecommended)
        if usesRecommended.wrappedValue {
            if let recommended {
                Text("\(recommended.bitrateKbps/1000) Mbps for \(recommended.width) × \(recommended.height) at \(recommended.fps) fps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Bitrate") {
                HStack {
                    TextField("Bitrate",value:chosen,format:.number.grouping(.never)).labelsHidden().multilineTextAlignment(.trailing).frame(width:64)
                    Text("Mbps")
                    Stepper("Bitrate",value:chosen,in:StreamPreferences.bitrates,step:5).labelsHidden()
                }
            }
            Text("Higher is sharper and needs a faster network.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
