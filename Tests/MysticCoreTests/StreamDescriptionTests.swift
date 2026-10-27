import Testing
@testable import MysticCore

/// Fixture modelled on a Rubylight/Apollo `DESCRIBE` answer: multichannel game
/// audio, a separate mono microphone stream, and the Sunshine-family `x-ss-*`
/// capability extensions.
private let hostSDP = """
v=0
o=rtsp 0 0 IN IP4 192.168.1.10
s=Rubylight
c=IN IP4 0.0.0.0
t=0 0
a=x-ss-general.encryptionSupported:1
a=x-ss-general.encryptionRequested:1
m=video 47998 RTP/AVP 96 97 98
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1
a=rtpmap:97 HEVC/90000
a=fmtp:97 packetization-mode=1
a=rtpmap:98 AV1/90000
a=rtpmap:98 x-ss-general.av1:1
m=audio 48000 RTP/AVP 96
a=rtpmap:96 opus/48000/2
a=fmtp:96 minptime=10;useinbandfec=1
m=audio 48001 RTP/AVP 96
a=rtpmap:96 opus/48000/1
a=fmtp:96 minptime=10;useinbandfec=1
"""

@Suite("Stream description")
struct StreamDescriptionTests {

    let description = MysticCore.StreamDescription.parse(hostSDP)

    @Test("reads the session name")
    func sessionName() {
        #expect(description.sessionName == "Rubylight")
    }

    @Test("splits the media sections by kind")
    func sections() {
        #expect(description.videoSections.count == 1)
        #expect(description.audioSections.count == 2)
        #expect(description.videoSections.first?.port == 47998)
    }

    @Test("collects every offered encoding once")
    func encodings() {
        #expect(description.offeredEncodings == ["H264", "HEVC", "AV1", "OPUS"])
    }

    @Test("keeps the payload mappings with their clock rate")
    func mappings() {
        let video = description.videoSections[0].mappings
        #expect(video.count == 3)
        #expect(video[1].encoding == "HEVC")
        #expect(video[1].clockRate == 90000)
    }

    @Test("keeps fmtp parameters")
    func formatParameters() {
        let audio = description.audioSections[0].mappings[0]
        #expect(audio.formatParameters["minptime"] == "10")
        #expect(audio.formatParameters["useinbandfec"] == "1")
    }

    @Test("distinguishes multichannel audio from the mono mic stream")
    func audioChannels() {
        #expect(description.audioSections[0].mappings[0].channelCount == 2)
        #expect(description.audioSections[1].mappings[0].channelCount == 1)
        #expect(description.offersMultichannelAudio)
    }

    @Test("reads the encryption requirement from the extensions")
    func encryption() {
        #expect(description.requiresEncryption)
        #expect(description.extendedValue("x-ss-general.encryptionSupported") == "1")
    }

    @Test("an unencrypted host is not treated as requiring encryption")
    func plainHost() {
        let plain = MysticCore.StreamDescription.parse("v=0\ns=Old\na=x-ss-general.encryptionSupported:0\n")
        #expect(!plain.requiresEncryption)
        #expect(plain.sessionName == "Old")
    }

    @Test("malformed lines are ignored instead of failing the parse")
    func robustness() {
        let broken = MysticCore.StreamDescription.parse("v=0\nm=video notaport RTP/AVP 96\na=rtpmap:96\njunk\n")
        #expect(broken.sections.isEmpty)
        #expect(broken.offeredEncodings.isEmpty)
    }
}
