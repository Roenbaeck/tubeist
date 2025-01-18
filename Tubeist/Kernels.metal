#include <metal_stdlib>
using namespace metal;

/* -------------=============== STYLES ===============------------- */
kernel void saturation(texture2d<float, access::read_write> yTexture [[texture(0)]],
                       texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                       constant float &strength [[buffer(0)]],
                       constant float &frame [[buffer(1)]],
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
                   constant float &frame [[buffer(1)]],
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
                 constant float &frame [[buffer(1)]],
                 uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float4 chroma = cbcrTexture.read(gid);

    float y = luma.r;
    float cb = chroma.r;
    float cr = chroma.g;

    // Lift Blacks and Tone Down Whites (film-like base tone)
    float blackLift = 0.05 * abs(strength);
    float whiteToneDown = 1.00 - 0.05 * abs(strength);
    float adjustedY = y * whiteToneDown + blackLift * (1.0 - y);
        
    // Filmic S-Curve for contrast
    float sCurveY = adjustedY / (adjustedY + 0.5 * (1.0 - adjustedY));

    // Warm shadows and cool highlights
    float warmCoolBlend = 0.03;
    float shadowTint = 0.02; // warm tone
    float highlightTint = -0.02; // cool tone
    float hueShift = (sCurveY < 0.5) ? shadowTint : highlightTint;
    cb += hueShift * warmCoolBlend;
    cr -= hueShift * warmCoolBlend;

    // Subtle color adjust
    float cbAdjust =  0.02 * strength;
    float crAdjust = -0.02 * strength;
    float mid = 0.5;
    float newCb = mix(cb, mid, cbAdjust);
    float newCr = mix(cr, mid, crAdjust);

    // Bloom or Halation Simulation
    float bloomFactor = smoothstep(0.8, 1.0, sCurveY);
    sCurveY += bloomFactor * 0.05 * abs(strength);

    // Write back (saturate for final output)
    yTexture.write(float4(saturate(sCurveY), 0, 0, 0), gid);
    cbcrTexture.write(float4(saturate(newCb), saturate(newCr), 0, 0), gid);
}


kernel void blackbright(texture2d<float, access::read_write> yTexture [[texture(0)]],
                        texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                        constant float &strength [[buffer(0)]],
                        constant float &frame [[buffer(1)]],
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
                  constant float &frame [[buffer(1)]],
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
                      constant float &frame [[buffer(1)]],
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
    
    // Handle EDR values
    bool isEDR = y > 1.0;
    float normalizedY = isEDR ? log2(y + 1.0) / 2.0 : y;
    float posterizedY = floor(normalizedY * levels) / levels;
    float finalY = isEDR ? exp2(posterizedY * 2.0) - 1.0 : posterizedY;

    // Apply edge detection
    float edgeWidth = mix(4.0, 1.0, strength);
    float lift = 1.25 + 0.25 * strength;
    finalY = edgeStrength > edgeThreshold / edgeWidth ? 0.05 : lift * finalY;
    
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

/* -------------=============== EFFECTS ===============------------- */
kernel void sky(texture2d<float, access::read_write> yTexture [[texture(0)]],
                texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                constant float &strength [[buffer(0)]],
                constant float &frame [[buffer(1)]],
                uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float y = luma.r;
    
    // Get the height of the texture (assuming the dispatch size matches the texture size)
    uint textureHeight = yTexture.get_height();
    
    // Calculate the vertical position as a normalized value (0.0 at the top, 1.0 at the bottom)
    float normalizedY = (float)gid.y / (float)(textureHeight - 1.0); // Subtract 1 to handle 0-based indexing
    
    // We want the gradient to be strongest at the top and fade towards the middle.
    // Let's define the middle point (where the gradient effect is minimal).
    float middlePoint = 0.5;
    
    // Calculate the gradient factor. We only apply the gradient above the middle.
    float gradientFactor = 0.0;
    if (normalizedY < middlePoint) {
        // Scale the gradient effect based on the distance from the top.
        // At the top (normalizedY = 0), the factor is 1.
        // At the middle (normalizedY = middlePoint), the factor is 0.
        
        // Option 1: Linear falloff
        // gradientFactor = 1.0 - (normalizedY / middlePoint);
        
        // Option 2: More controlled falloff with a power function (adjust the exponent)
        float power = 2.0; // You can adjust this for different curves
        gradientFactor = pow(1.0 - (normalizedY / middlePoint), power);
    }
    
    // Apply the darkening effect to the luma component.
    // We subtract the gradient factor multiplied by the strength.
    // Note that 'strength' here now controls the darkness amount.
    // Reduce the max darkening to 0.8 instead of 1.0.
    float darkenedY = y - (0.8 * gradientFactor * strength);
    
    // Clamp the value to ensure it stays within the valid range (0.0 to 1.0)
    darkenedY = clamp(darkenedY, 0.0, 1.0);
    
    yTexture.write(float4(darkenedY, 0, 0, 0), gid);
}

kernel void vignette(texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     constant float &strength [[buffer(0)]],
                     constant float &frame [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float4 luma = yTexture.read(gid);
    float y = luma.r;

    uint width = yTexture.get_width();
    uint height = yTexture.get_height();

    // Calculate the center of the texture
    float2 center = float2(width / 2.0, height / 2.0);

    // Calculate the distance from the current pixel to the center
    float2 currentPosition = float2(gid.x, gid.y);
    float distance = length(currentPosition - center);

    // Calculate the maximum possible distance (corner to center)
    float maxDistance = length(float2(0.0, 0.0) - center);

    // Normalize the distance to a 0-1 range (0 at center, 1 at corners)
    float normalizedDistance = distance / maxDistance;

    // Define the point where the vignette effect starts (1/3 of the way to the center)
    float vignetteStart = 1.0 / 3.0;

    // Calculate the vignette factor
    float vignetteFactor = 0.0;
    if (normalizedDistance > vignetteStart) {
        // Remap the normalized distance to the range [0, 1] where 0 is the start of the effect and 1 is the edge
        float effectDistance = (normalizedDistance - vignetteStart) / (1.0 - vignetteStart);
        effectDistance = clamp(effectDistance, 0.0, 1.0); // Ensure it stays within 0-1

        // Apply falloff to the effect distance
        vignetteFactor = smoothstep(0.0, 1.0, effectDistance);
    }

    // Apply the darkening effect. Strength controls the intensity.
    float darkenedY = y * (1.0 - (vignetteFactor * strength));

    yTexture.write(float4(darkenedY, 0, 0, 0), gid);
}

kernel void pixelate(texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     constant float &strength [[buffer(0)]],
                     constant float &frame [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {

    uint width = yTexture.get_width();
    uint height = yTexture.get_height();

    // Calculate the size of the pixelated blocks based on strength.
    // Lower strength means larger blocks, so we invert and scale.
    float blockSizeFloat = 1.0 + (1.0 - strength) * 31.0; // Adjust 31.0 for max block size
    uint blockSize = uint(blockSizeFloat);

    // Calculate the top-left coordinate of the pixelated block for the current pixel.
    uint blockStartX = (gid.x / blockSize) * blockSize;
    uint blockStartY = (gid.y / blockSize) * blockSize;

    // Sample the input textures at the top-left of the block.
    uint2 sampleCoord = uint2(blockStartX, blockStartY);

    // Ensure the sample coordinate is within the texture bounds.
    if (sampleCoord.x < width && sampleCoord.y < height) {
        float4 sampledY = yTexture.read(sampleCoord);
        float4 sampledCbCr = cbcrTexture.read(sampleCoord);

        yTexture.write(sampledY, gid);
        cbcrTexture.write(sampledCbCr, gid);
    }
}

kernel void grain(texture2d<float, access::read_write> yTexture [[texture(0)]],
                  texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                  constant float &strength [[buffer(0)]],
                  constant float &frame [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    float4 color = yTexture.read(gid);
    float y = color.r;
    
    // Create pseudo-random noise based on position and time
    float2 resolution = float2(yTexture.get_width(), yTexture.get_height());
    float2 uv = float2(gid) / resolution;
    
    // Multi-octave noise for more natural looking grain
    float noise = 0.0;
    float frequency = 1.0;
    float amplitude = 1.0;
    float persistence = mix(0.5, 1.0, strength);
    
    for (int i = 0; i < 3; i++) {
        float2 coord = uv * frequency + float2(frame * 0.1, frame * 0.2);
        
        // Generate noise using hash function
        float2 p = fract(coord * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        float n = fract(p.x * p.y);
        
        noise += n * amplitude;
        frequency *= 2.0;
        amplitude *= persistence;
    }
    
    // Normalize noise to [-1, 1] range
    noise = noise * 2.0 - 1.0;
    
    // Make grain intensity dependent on luminance
    float grainAmount = mix(0.08, 0.02, smoothstep(0.2, 0.8, y));
    grainAmount *= strength;
    
    // Apply grain with HDR consideration
    float grainStrength = noise * grainAmount;
    float newY = y * (1.0 + grainStrength);
    
    // Write back
    yTexture.write(float4(newY, 0, 0, 0), gid);
}



