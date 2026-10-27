#!/usr/bin/env python3
"""CC0 synthetic tones; FFmpeg needs libopus. Usage: script [path/to/ffmpeg]."""
import base64, json, pathlib, struct, subprocess, sys
ff = sys.argv[1] if len(sys.argv) > 1 else 'ffmpeg'
root = pathlib.Path(__file__).resolve().parents[1]
for name, count, mask, order in [('stereo',2,3,[0,1]), ('surround51',6,0x3f,[0,2,1,5,3,4])]:
    frequencies = [250 + 100*i for i in range(count)]
    expression = '|'.join('0.1*sin(2*PI*%d*t)' % n for n in frequencies)
    source = 'aevalsrc=' + expression + ':s=48000:d=0.3:c=' + ('stereo' if count==2 else '5.1')
    ogg = subprocess.check_output([ff,'-v','error','-f','lavfi','-i',source,'-c:a','libopus',
        '-application','lowdelay','-frame_duration','5','-b:a',str(count*64000),'-f','opus','-'])
    packets=[]; packet=bytearray(); cursor=0
    while cursor<len(ogg):
        assert ogg[cursor:cursor+4] == b'OggS'
        n=ogg[cursor+26]; laces=ogg[cursor+27:cursor+27+n]; cursor += 27+n
        for length in laces:
            packet.extend(ogg[cursor:cursor+length]); cursor+=length
            if length<255: packets.append(bytes(packet)); packet.clear()
    head=packets[0]; assert head[:8]==b'OpusHead'
    if head[18]==0: streams,coupled,mapping=1,1,[0,1]
    else:
        streams,coupled=head[19:21]; original=list(head[21:21+count]); mapping=[original[i] for i in order]
    result=dict(sampleRate=48000,channelCount=count,channelMask=mask,streams=streams,
        coupledStreams=coupled,mapping=mapping,samplesPerFrame=240,packetDurationMs=5,
        frequencies=frequencies,packets=[base64.b64encode(p).decode() for p in packets[2:]])
    dest=root/'Tests/MysticStreamTests/Fixtures'/('audio-'+name+'.json')
    dest.write_text(json.dumps(result,indent=2)+'\n')
