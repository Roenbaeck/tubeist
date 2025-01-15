#include <metal_stdlib>
using namespace metal;

kernel void grayscale(texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    
    float y = luma.r;
    
    yTexture.write(float4(y, 0, 0, 0), gid);
    cbcrTexture.write(float4(0.5, 0.5, 0, 0), gid);
}

kernel void warmer(texture2d<float, access::read_write> yTexture [[texture(0)]],
                   texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    float crFactor = 1.025; // Slightly increase red
    float cbFactor = 0.950; // Decrease blue
    float  yFactor = 1.015; // Add a touch of brightness
    
    yTexture.write(float4(y * yFactor, 0, 0, 0), gid);
    cbcrTexture.write(float4(cb * cbFactor, cr * crFactor, 0, 0), gid);
}

kernel void colder(texture2d<float, access::read_write> yTexture [[texture(0)]],
                   texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    float crFactor = 0.975; // Slightly decrease red
    float cbFactor = 1.050; // Increase blue
    float  yFactor = 0.985; // Add a touch of darkness
    
    yTexture.write(float4(y * yFactor, 0, 0, 0), gid);
    cbcrTexture.write(float4(cb * cbFactor, cr * crFactor, 0, 0), gid);
}

kernel void film(texture2d<float, access::read_write> yTexture [[texture(0)]],
                 texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                 uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);

    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;

    // Lift Blacks and Tone Down Whites (on HDR values)
    float blackLift = 0.05;
    float whiteToneDown = 0.95;
    float adjustedY = y * whiteToneDown + blackLift * (1.0 - y);

    // Subtle Desaturation (on HDR chroma)
    float desaturation = 0.03;
    float mid = 0.5;
    float newCb = mix(cb, mid, desaturation);
    float newCr = mix(cr, mid, desaturation);

    // Some final tone mapping
    newCb = newCb * 0.98;
    newCr = newCr * 1.01;
    float newY = adjustedY * 1.03;

    // Write back (saturate for final output if necessary)
    yTexture.write(float4(newY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

kernel void blackerwhiter(texture2d<float, access::read_write> yTexture [[texture(0)]],
                          texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    
    float y = luma.r;

    // Apply a contrast adjustment
    float contrast = 1.85;
    float midPoint = 0.5;
    float normalizedY = (y - midPoint);
    float contrastedY = midPoint + (normalizedY * contrast);

    yTexture.write(float4(contrastedY, 0, 0, 0), gid);
    cbcrTexture.write(float4(0.5, 0.5, 0, 0), gid);
}

kernel void wild(texture2d<float, access::read_write> yTexture [[texture(0)]],
                   texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    float newCr = 1.0 - cr;
    float newCb = 1.0 - cb;

    float contrast = 1.2;
    float midPoint = 0.2;
    float normalizedY = (y - midPoint);
    float contrastedY = midPoint + (normalizedY * contrast);
    
    yTexture.write(float4(contrastedY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

