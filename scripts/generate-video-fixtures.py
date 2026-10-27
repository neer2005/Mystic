#!/usr/bin/env python3
"""Generate CC0 synthetic profile fixtures; requires FFmpeg with x264/x265/libaom.
Usage: python3 scripts/generate-video-fixtures.py /path/to/ffmpeg
"""
import subprocess, pathlib, sys
ff = sys.argv[1] if len(sys.argv) > 1 else 'ffmpeg'
out=pathlib.Path(__file__).resolve().parents[1] / 'Sources/MysticStream/Fixtures';out.mkdir(exist_ok=True)
formats=[('h264',1,'libx264','yuv420p','h264'),('h264-444',4,'libx264','yuv444p','h264'),('hevc',256,'libx265','yuv420p','hevc'),('hevc-10',512,'libx265','yuv420p10le','hevc'),('hevc-444',1024,'libx265','yuv444p','hevc'),('hevc-10-444',2048,'libx265','yuv444p10le','hevc'),('av1',4096,'libaom-av1','yuv420p','obu'),('av1-10',8192,'libaom-av1','yuv420p10le','obu'),('av1-444',16384,'libaom-av1','yuv444p','obu'),('av1-10-444',32768,'libaom-av1','yuv444p10le','obu')]
for name,bit,encoder,pix,container in formats:
 hdr='10' in name
 cmd=[ff,'-v','error','-f','lavfi','-i','testsrc2=size=64x64:rate=60','-frames:v','1','-pix_fmt',pix,'-c:v',encoder,'-color_primaries','bt2020' if hdr else 'bt709','-color_trc','smpte2084' if hdr else 'bt709','-colorspace','bt2020nc' if hdr else 'bt709','-color_range','tv']
 if encoder=='libx265': cmd+=['-x265-params','log-level=error:pools=1:frame-threads=1'+(':hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400' if hdr else '')]
 if encoder=='libaom-av1':cmd+=['-cpu-used','8','-row-mt','1']
 cmd+=['-f',container,'-y',str(out/(name+'.bin'))]
 subprocess.run(cmd,check=True)
 print(name,flush=True)

# Decoder integration cases: two dependent access units and a changed SPS/resolution.
tests = out.parents[2] / 'Tests/MysticStreamTests/Fixtures'
tests.mkdir(parents=True, exist_ok=True)
for size, name, count in [('64x64', 'gop', '2'), ('128x64', 'resize', '1')]:
    encoded = subprocess.check_output([ff, '-v', 'error', '-f', 'lavfi', '-i',
        'testsrc2=size=' + size + ':rate=60', '-frames:v', count, '-c:v', 'libx264',
        '-preset', 'ultrafast', '-tune', 'zerolatency', '-x264-params', 'aud=1:keyint=60',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
        '-f', 'h264', '-'])
    if name == 'gop':
        boundary = encoded.index(bytes([0,0,0,1,9]), 5)
        (tests / 'h264-key.bin').write_bytes(encoded[:boundary])
        (tests / 'h264-p.bin').write_bytes(encoded[boundary:])
    else:
        (tests / 'h264-resize.bin').write_bytes(encoded)
