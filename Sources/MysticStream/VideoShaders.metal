// Mystic's video shaders. The app ships them compiled (scripts/build-macos-app.sh); tests and
// `swift run` compile this source at runtime (MetalVideoPipelines.library).
#include <metal_stdlib>
using namespace metal;
/// `toneMap` is 1 for a PQ frame whose peak is above the screen's (HDRToneMap); the peaks are PQ
/// code values.
struct Conversion { float yOffset,yScale,cOffset,cScale,codeScale,kr,kb,toneMap,sourcePeak,displayPeak; };
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex videoVertex(uint id [[vertex_id]]) {
    float2 uv=float2((id << 1) & 2,id & 2);
    return { float4(uv*float2(2,-2)+float2(-1,1),0,1),uv };
}
/// BT.2390's EETF on PQ code values, per component; HDRToneMap.map is the same on the CPU.
static float3 eetf(float3 value,float sourcePeak,float displayPeak) {
    float3 e1=saturate(value/sourcePeak);
    float maxLum=displayPeak/sourcePeak,knee=max(0.0,1.5*maxLum-0.5);
    float3 t=(e1-knee)/(1-knee),t2=t*t,t3=t2*t;
    float3 spline=(2*t3-3*t2+1)*knee+(t3-2*t2+t)*(1-knee)+(-2*t3+3*t2)*maxLum;
    return min(select(spline,e1,e1 <= knee)*sourcePeak,displayPeak);
}
fragment float4 videoFragment(Vertex in [[stage_in]],texture2d<float> luma [[texture(0)]],texture2d<float> chroma [[texture(1)]],
                              constant Conversion &c [[buffer(0)]]) {
    constexpr sampler linear(filter::linear,address::clamp_to_edge);
    float y=(luma.sample(linear,in.uv).r*c.codeScale-c.yOffset)/c.yScale;
    float2 uv=(chroma.sample(linear,in.uv).rg*c.codeScale-c.cOffset)/c.cScale;
    float r=y+2*(1-c.kr)*uv.y,b=y+2*(1-c.kb)*uv.x;
    float g=(y-c.kr*r-c.kb*b)/(1-c.kr-c.kb);
    float3 rgb=saturate(float3(r,g,b));
    if (c.toneMap > 0) { rgb=eetf(rgb,c.sourcePeak,c.displayPeak); }
    return float4(rgb,1);
}
