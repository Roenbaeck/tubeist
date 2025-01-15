#include <metal_stdlib>
using namespace metal;

kernel void grayscale(texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
//    float4 chroma = cbcrTexture.read(gid);

    float y = luma.r;
//    float cb = chroma.r;
//    float cr = chroma.g;
    
    yTexture.write(float4(y, 0, 0, 0), gid);
    cbcrTexture.write(float4(0.5, 0.5, 0, 0), gid);
}

