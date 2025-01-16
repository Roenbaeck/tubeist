#include <metal_stdlib>
using namespace metal;

kernel void saturation(texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      constant float &strength [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);

    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;

    float newY = y;
    float newCb = mix(cb, 0.5, strength);
    float newCr = mix(cr, 0.5, strength);
    
    yTexture.write(float4(newY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

kernel void warmth(texture2d<float, access::read_write> yTexture [[texture(0)]],
                   texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                   constant float &strength [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    float  yFactor = 1.03; // Add a touch of brightness
    float cbFactor = 0.90; // Decrease blue
    float crFactor = 1.05; // Slightly increase red
    
    float newY = mix(y, y * yFactor, strength);
    float newCb = mix(cb, cb * cbFactor, strength);
    float newCr = mix(cr, cr * crFactor, strength);
    
    yTexture.write(float4(newY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

kernel void film(texture2d<float, access::read_write> yTexture [[texture(0)]],
                 texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                 constant float &strength [[buffer(0)]],
                 uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    // Lift Blacks and Tone Down Whites (on HDR values)
    float blackLift = mix(0, 0.05, strength);
    float whiteToneDown = mix(1.0, 0.95, strength);
    float adjustedY = y * whiteToneDown + blackLift * (1.0 - y);
    
    // Subtle Desaturation (on HDR chroma)
    float desaturation = mix(0, 0.03, strength);
    float mid = 0.5;
    float newCb = mix(cb, mid, desaturation);
    float newCr = mix(cr, mid, desaturation);
    
    // Some final tone mapping
    newCb = mix(newCb, newCb * 0.98, strength);
    newCr = mix(newCr, newCr * 1.01, strength);
    float newY = mix(adjustedY, adjustedY * 1.03, strength);
    
    // Write back (saturate for final output if necessary)
    yTexture.write(float4(newY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

kernel void blackbright(texture2d<float, access::read_write> yTexture [[texture(0)]],
                        texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                        constant float &strength [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    
    float y = luma.r;
    
    // Apply a contrast adjustment
    float contrast = 1.85;
    float midPoint = 0.5 * strength;
    float normalizedY = (y - midPoint);
    float contrastedY = midPoint + (normalizedY * contrast);
    
    yTexture.write(float4(contrastedY, 0, 0, 0), gid);
    cbcrTexture.write(float4(0.5, 0.5, 0, 0), gid);
}

kernel void space(texture2d<float, access::read_write> yTexture [[texture(0)]],
                  texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                  constant float &strength [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);
    
    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;
    
    float newCr = mix(1.0 - cb, 1.0 - cr, strength);
    float newCb = mix(1.0 - cr, 1.0 - cb, strength);
    
    float contrast = 1.2;
    float midPoint = 0.2;
    float normalizedY = (y - midPoint);
    float contrastedY = midPoint + (normalizedY * contrast);
    
    yTexture.write(float4(contrastedY, 0, 0, 0), gid);
    cbcrTexture.write(float4(newCb, newCr, 0, 0), gid);
}

kernel void rotoscope(texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     constant float &strength [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    
    float edgeThreshold = 0.1;
    // Early exit if outside texture bounds
    if (gid.x >= yTexture.get_width() || gid.y >= yTexture.get_height()) {
        return;
    }
    
    // Get center pixel values
    float4 lumaCenter = yTexture.read(gid);
    float4 chromaCenter = cbcrTexture.read(gid);
    
    // Sample neighboring pixels for edge detection (Y plane only)
    uint2 textureSize = uint2(yTexture.get_width(), yTexture.get_height());
    
    // Ensure we don't read outside texture bounds
    uint2 leftPos = uint2(gid.x > 0 ? gid.x - 1 : gid.x, gid.y);
    uint2 rightPos = uint2(gid.x < textureSize.x - 1 ? gid.x + 1 : gid.x, gid.y);
    uint2 upPos = uint2(gid.x, gid.y > 0 ? gid.y - 1 : gid.y);
    uint2 downPos = uint2(gid.x, gid.y < textureSize.y - 1 ? gid.y + 1 : gid.y);
    
    float lumaLeft = yTexture.read(leftPos).r;
    float lumaRight = yTexture.read(rightPos).r;
    float lumaUp = yTexture.read(upPos).r;
    float lumaDown = yTexture.read(downPos).r;
    
    // Improved edge detection with reduced thread group boundary artifacts
    float2 gradient;
    gradient.x = (gid.x % 16 == 0) ? 0.0 : lumaRight - lumaLeft;
    gradient.y = (gid.y % 16 == 0) ? 0.0 : lumaDown - lumaUp;
    float edgeStrength = length(gradient);
    
    // Posterization on luma with EDR handling
    float y = lumaCenter.r;
    float levels = 4;

    // Add subtle noise to break up perfectly flat areas
    float noise = fract(sin(dot(float2(gid), float2(12.9898, 78.233))) * 43758.5453);
    noise = (noise - 0.5) * 0.015;  // Very subtle noise
    
    // Handle EDR values
    bool isEDR = y > 1.0;
    float normalizedY = isEDR ? log2(y + 1.0) / 2.0 : y;
    float posterizedY = floor((normalizedY + noise) * levels) / levels;
    float finalY = isEDR ? exp2(posterizedY * 2.0) - 1.0 : posterizedY;

    // Apply edge detection
    float edgeWidth = mix(4.0, 1.0, strength);
    finalY = edgeStrength > edgeThreshold / edgeWidth ? 0.05 : 1.5 * finalY;
    
    // Get chroma values
    float cb = chromaCenter.r;
    float cr = chromaCenter.g;
    
    // Calculate distance from neutral (0.5, 0.5)
    float2 chromaDist = float2(cb - 0.5, cr - 0.5);
    float chromaLength = length(chromaDist);
    
    // More conservative chroma quantization
    uint numColorShades = 8;
    
    // Only quantize if there's significant color
    float colorThreshold = 0.2;
    if (chromaLength > colorThreshold) {
        // Quantize the chroma values while preserving the angle
        float quantizedLength = floor(chromaLength * float(numColorShades)) / float(numColorShades);
        float2 normalizedChroma = chromaDist / chromaLength;
        chromaDist = normalizedChroma * quantizedLength;
    } else {
        // If close to neutral, push towards neutral
        chromaDist *= 0.5;
    }
    
    // Convert back to cb/cr
    float quantizedCb = chromaDist.x + 0.5;
    float quantizedCr = chromaDist.y + 0.5;
    
    // Write results
    yTexture.write(float4(finalY, 0, 0, 0), gid);
    cbcrTexture.write(float4(quantizedCb, quantizedCr, 0, 0), gid);
}

