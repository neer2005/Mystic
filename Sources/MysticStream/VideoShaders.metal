// Mystic's video shaders. The app ships them compiled (scripts/build-macos-app.sh); tests and
// `swift run` compile this source at runtime (MetalVideoPipelines.library).
#include <metal_stdlib>
using namespace metal;
struct Conversion { float yOffset,yScale,cOffset,cScale,codeScale,kr,kb; };
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex videoVertex(uint id [[vertex_id]]) {
    float2 uv=float2((id << 1) & 2,id & 2);
    return { float4(uv*float2(2,-2)+float2(-1,1),0,1),uv };
}
fragment float4 videoFragment(Vertex in [[stage_in]],texture2d<float> luma [[texture(0)]],texture2d<float> chroma [[texture(1)]],
                              constant Conversion &c [[buffer(0)]]) {
    constexpr sampler linear(filter::linear,address::clamp_to_edge);
    float y=(luma.sample(linear,in.uv).r*c.codeScale-c.yOffset)/c.yScale;
    float2 uv=(chroma.sample(linear,in.uv).rg*c.codeScale-c.cOffset)/c.cScale;
    float r=y+2*(1-c.kr)*uv.y,b=y+2*(1-c.kb)*uv.x;
    float g=(y-c.kr*r-c.kb*b)/(1-c.kr-c.kb);
    return float4(saturate(float3(r,g,b)),1);
}
