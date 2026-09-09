#include <metal_stdlib>
using namespace metal;

// Create an argument buffer to provide a layer of indirection and thereby improve performance
struct KernelArguments {
    float strength;
    uint frame;
    uint threadgroupWidth;
    uint threadgroupHeight;
    uint widthRatio;
    uint heightRatio;
};

/* -------------=============== STYLES ===============------------- */
kernel void film(constant KernelArguments &args [[buffer(0)]],
                 texture2d<float, access::read_write> yTexture [[texture(0)]],
                 texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                 uint2 gid [[thread_position_in_grid]]) {
    
    float y = yTexture.read(gid).r;

    // Lift Blacks and Tone Down Whites (film-like base tone)
    float blackLift = 0.04 * (args.strength + 1);
    float whiteToneDown = 1.0 - blackLift;
    float adjustedY = y * whiteToneDown + blackLift * (1.0 - y);
        
    // Filmic S-Curve for contrast
    float sCurveY = adjustedY / (adjustedY + 0.5 * (1.0 - adjustedY));
    adjustedY = mix(adjustedY, sCurveY, abs(1.0 - args.strength) / 2.0);

    // Write back (saturate for final output)
    yTexture.write(adjustedY, gid); // Single-channel write
    
    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float4 chroma = cbcrTexture.read(cbcrGid);
        
        float hueShift = (adjustedY < 0.5) ? 0.04 : -0.04; // Inline constants
        float blend = 0.15 + 0.10 * args.strength;
        cbcrTexture.write(float4(chroma.r + hueShift * blend, chroma.g - hueShift * blend, 0, 0), cbcrGid);
    }
}

kernel void blackbright(constant KernelArguments &args [[buffer(0)]],
                        texture2d<float, access::read_write> yTexture [[texture(0)]],
                        texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float y = yTexture.read(gid).r;
    float midPoint = 0.5 * args.strength;
    float contrastedY = midPoint + (y - midPoint) * 1.85;
    
    yTexture.write(contrastedY, gid);
    
    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        cbcrTexture.write(float4(0.5, 0.5, 0, 0), cbcrGid);
    }
}

kernel void space(constant KernelArguments &args [[buffer(0)]],
                  texture2d<float, access::read_write> yTexture [[texture(0)]],
                  texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float4 chroma = cbcrTexture.read(cbcrGid);
        
        float cb = chroma.r;
        float cr = chroma.g;
        float newCr = mix(1.0 - cb, 1.0 - cr, args.strength);
        float newCb = mix(1.0 - cr, 1.0 - cb, args.strength);
        
        cbcrTexture.write(float4(newCb, newCr, 0, 0), cbcrGid);
    }
}

float quantizeNonLinear(float value, float numSteps) {
    float x = value * numSteps;
    float stepped = floor(x);
    // Apply non-linear spacing between levels
    return pow(stepped / numSteps, 0.8); // Adjust power for different curves
}

kernel void rotoscope(constant KernelArguments &args [[buffer(0)]],
                      texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {

    float edgeThreshold = 0.1;
    uint numColorShades = 8;

    // Get texture dimensions
    int yWidth = yTexture.get_width();
    int yHeight = yTexture.get_height();
    
    // Get center pixel values
    float4 lumaCenter = yTexture.read(gid);
    
    // Sample neighboring pixels for edge detection (Y plane only)
    uint2 textureSize = uint2(yWidth, yHeight);
    
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
    gradient.x = (gid.x % args.threadgroupWidth == 0) ? 0.0 : lumaRight - lumaLeft;
    gradient.y = (gid.y % args.threadgroupHeight == 0) ? 0.0 : lumaDown - lumaUp;
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
    float edgeWidth = mix(4.0, 1.0, args.strength);
    float lift = 1.25 + 0.25 * args.strength;

    // Calculate blending factor based on edge detection
    float edgeFactor = smoothstep(edgeThreshold / edgeWidth, edgeThreshold / (edgeWidth * 0.8), edgeStrength);

    // Adjust finalY with normalized blending
    float highlight = 0.05; // Minimal brightness for edges
    float adjustedFinalY = mix(finalY, highlight, edgeFactor);

    // Normalize brightness to compensate for blending
    float normalizationFactor = mix(1.0, lift, edgeFactor);
    finalY = adjustedFinalY * normalizationFactor;

    // Write results
    yTexture.write(float4(finalY, 0, 0, 0), gid);

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        
        float4 chromaCenter = cbcrTexture.read(cbcrGid);
        
        // Get chroma values
        float cb = chromaCenter.r;
        float cr = chromaCenter.g;
        
        // Calculate distance from neutral (0.5, 0.5)
        float2 chromaDist = float2(cb - 0.5, cr - 0.5);
        // Calculate chroma length (distance from neutral)
        float chromaLength = length(chromaDist);
        
        // Boost more for less saturated colors
        float saturationBoost = 1.0 + (0.5 * (1.0 - chromaLength));
        chromaDist *= saturationBoost;
        
        // Only quantize if there's significant color
        float colorThreshold = 0.25;
        if (chromaLength > colorThreshold) {
            // Quantize the chroma values while preserving the angle
            float quantizedLength = quantizeNonLinear(chromaLength, float(numColorShades));
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
        cbcrTexture.write(float4(quantizedCb, quantizedCr, 0, 0), cbcrGid);
    }
}

kernel void vhs(constant KernelArguments &args [[buffer(0)]],
                texture2d<float, access::read_write> yTexture [[texture(0)]],
                texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                uint2 gid [[thread_position_in_grid]]) {

    // Get texture dimensions
    int yWidth = yTexture.get_width();
    int yHeight = yTexture.get_height();

    // --- VHS Banding Implementation --- (Existing code, keeping it)
    float bandIntensity = args.strength;
    int bandHeight = max(1, int(bandIntensity * 8.0));
    int bandIndex = gid.y / bandHeight;

    float bandingFactor = 1.0;

    float noise = fract(sin(dot(float2(gid) + float2(args.frame * 0.5), float2(12.9898, 78.233))) * 43758.5453);
    float randomOffset = (noise - 0.5) * 0.1 * bandIntensity;

    if (bandIndex % 2 == 0) {
        bandingFactor = max(0.7, 1.0 - (0.1 * bandIntensity) - randomOffset);
    } else {
        bandingFactor = min(1.3, 1.0 + (0.05 * bandIntensity) + randomOffset);
    }

    // --- VHS Horizontal Edge Distortion ---
    float distortionAmplitude = args.strength * 50.0;            // Control distortion amplitude with strength
    float distortionFrequency = 0.02 + 0.02 * randomOffset; // Frequency of the sine wave for distortion
    float distortionSpeed = 0.1;                            // Speed of distortion animation

    float verticalDistortionFactor = 0.0;
    float verticalNoiseFactor = 0.0;

    // Define zones at the top and bottom where distortion and noise occurs (e.g., 4% height at top and bottom)
    float distortionZoneHeight = yHeight * 0.05f;

    if (gid.y < distortionZoneHeight) {
        // Top distortion zone - increase distortion/noise towards the very top
        verticalDistortionFactor = (distortionZoneHeight - gid.y) / distortionZoneHeight; // 1 at top, 0 at zone boundary
        verticalNoiseFactor = verticalDistortionFactor; // Noise factor same as distortion factor for now - can adjust separately
    }

    // Calculate horizontal distortion offset using sine wave WITH ERRATIC MODULATION
    float baseSine = -abs(sin(float(gid.x) * distortionFrequency + args.frame * distortionSpeed));  // Base sine wave
    float horizontalDistortion = (baseSine + randomOffset) * distortionAmplitude * verticalDistortionFactor;

    // --- Apply effects to Y texture ---
    float4 ySample;
    int2 distortedGidY = int2(gid); // Initialize with original gid for Y texture

    // Apply horizontal distortion to gid.x for Y texture read
    distortedGidY.x = clamp(int(gid.x + horizontalDistortion), 0, yWidth - 1); // Clamp to texture bounds
    
    ySample = yTexture.read(uint2(distortedGidY));
    float y = ySample.r;

    // Apply banding to the Y value
    y *= bandingFactor;

    // --- Add Luma Noise in Distortion Zones ---
    float edgeNoiseAmount = args.strength * verticalNoiseFactor; // Control noise amount, scaled by vertical factor and strength
    float edgeNoise = (fract(sin(dot(float2(gid) + float2(args.frame * 1.2), float2(54.123, 91.876))) * 43758.5453) - 0.5) * edgeNoiseAmount;
    
    y += edgeNoise * verticalDistortionFactor;

    // --- Horizontal White Line Defects ---
    float whiteLineProbability = args.strength * 0.001;  // Probability of a white line per row, adjust scale as needed
    float whiteLineIntensity = 0.7;                 // Intensity of white lines (additive to luma)
    float maxLineWidth = yWidth * 0.2;              // Maximum width of white lines in pixels

    float rowRandom = fract(sin(float(gid.y * 13 + args.frame * 7)) * 43758.5453); // Random per row and frame
    if (rowRandom < whiteLineProbability) {
        // Draw a white line
        float lineWidthRandom = fract(sin(float(gid.y * 31 + args.frame * 11)) * 43758.5453); // Different random for line width
        uint lineWidth = max(1, int(lineWidthRandom * maxLineWidth)); // Line width between 1 and maxLineWidth
        uint offset = min(uint(noise * yWidth), yWidth - lineWidth);

        if (gid.x > offset && gid.x < lineWidth + offset)
        {
             y += whiteLineIntensity;
        }
    }

    // Write the modified Y value back to the Y texture
    yTexture.write(float4(y, ySample.gba), gid);

    // --- Apply effects to CbCr texture ---
    int cbcrWidth = cbcrTexture.get_width();
    int cbcrHeight = cbcrTexture.get_height();

    // Calculate offset in Y-space (same as before, based on strength and frame)
    float2 offset = float2(0.01 * args.strength * yWidth, 0.01 * sin(M_PI_F * args.frame / 60.0) * yHeight);

    // Convert gid to cbcrTexture coordinates
    uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);

    // --- Apply horizontal distortion to CbCr as well ---
    uint2 distortedGidCbCr = cbcrGid; // Initialize with base CbCr gid

    // Apply horizontal distortion (same as for Y, but in CbCr space)
    distortedGidCbCr.x = clamp(int(cbcrGid.x + horizontalDistortion / args.widthRatio), 0, cbcrWidth - 1); // Scale distortion to CbCr space & clamp

    // Apply offsets in CbCr texture space
    uint2 cbGid_cbcr = distortedGidCbCr + uint2(offset.x / args.widthRatio, offset.y / args.heightRatio); // Use distorted GID here
    uint2 crGid_cbcr = distortedGidCbCr - uint2(offset.x / args.widthRatio, offset.y / args.heightRatio); // Use distorted GID here

    // Clamp CbCr GIDs to CbCr texture bounds
    cbGid_cbcr.x = clamp(int(cbGid_cbcr.x), 0, cbcrWidth - 1);
    cbGid_cbcr.x = cbGid_cbcr.x % args.threadgroupWidth == 0 ? cbcrGid.x : cbGid_cbcr.x;
    cbGid_cbcr.y = clamp(int(cbGid_cbcr.y), 0, cbcrHeight - 1);
    cbGid_cbcr.y = cbGid_cbcr.y % args.threadgroupHeight == 0 ? cbcrGid.y : cbGid_cbcr.y;
    crGid_cbcr.x = clamp(int(crGid_cbcr.x), 0, cbcrWidth - 1);
    crGid_cbcr.x = crGid_cbcr.x % args.threadgroupWidth == 0 ? cbcrGid.x : crGid_cbcr.x;
    crGid_cbcr.y = clamp(int(crGid_cbcr.y), 0, cbcrHeight - 1);
    crGid_cbcr.y = crGid_cbcr.y % args.threadgroupHeight == 0 ? cbcrGid.y : crGid_cbcr.y;

    // Sample Cb and Cr from cbcrTexture using distorted CbCr-space coordinates
    float4 cbcrSampleCb = cbcrTexture.read(uint2(cbGid_cbcr));
    float4 cbcrSampleCr = cbcrTexture.read(uint2(crGid_cbcr));

    // Write to cbcrTexture at the original CbCr-space gid (non-distorted base)
    cbcrTexture.write(float4(cbcrSampleCb.r, cbcrSampleCr.g, 0.0, 0.0), cbcrGid); // Use non-distorted base for write
}



/* -------------=============== EFFECTS ===============------------- */
kernel void sky(constant KernelArguments &args [[buffer(0)]],
                texture2d<float, access::read_write> yTexture [[texture(0)]],
                texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    
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
    float darkenedY = y - (0.8 * gradientFactor * args.strength);
    
    // Clamp the value to ensure it stays within the valid range (0.0 to 1.0)
    darkenedY = clamp(darkenedY, 0.0, 1.0);
    
    yTexture.write(darkenedY, gid);
}

kernel void vignette(constant KernelArguments &args [[buffer(0)]],
                     texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;

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
    float darkenedY = y * (1.0 - (vignetteFactor * args.strength));

    yTexture.write(darkenedY, gid);
}

kernel void saturation(constant KernelArguments &args [[buffer(0)]],
                       texture2d<float, access::read_write> yTexture [[texture(0)]],
                       texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        
        float4 chroma = cbcrTexture.read(cbcrGid);
        
        float cb = chroma.r;
        float cr = chroma.g;
        
        float newCb = mix(cb, 0.5, args.strength);
        float newCr = mix(cr, 0.5, args.strength);
        
        cbcrTexture.write(float4(newCb, newCr, 0, 0), cbcrGid);
    }
}

kernel void warmth(constant KernelArguments &args [[buffer(0)]],
                   texture2d<float, access::read_write> yTexture [[texture(0)]],
                   texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    
    float yFactor = 1.03; // Add a touch of brightness
    
    float newY = mix(y, y * yFactor, args.strength);
    
    yTexture.write(newY, gid);
    
    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float4 chroma = cbcrTexture.read(cbcrGid);
        
        float cb = chroma.r;
        float cr = chroma.g;
        
        float cbFactor = 0.90; // Decrease blue
        float crFactor = 1.05; // Slightly increase red
        
        float newCb = mix(cb, cb * cbFactor, args.strength);
        float newCr = mix(cr, cr * crFactor, args.strength);
        
        cbcrTexture.write(float4(newCb, newCr, 0, 0), cbcrGid);
    }
}

kernel void pixelate(constant KernelArguments &args [[buffer(0)]],
                     texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {

    uint width = yTexture.get_width();
    uint height = yTexture.get_height();

    // Calculate the size of the pixelated blocks based on strength.
    // Lower strength means larger blocks, so we invert and scale.
    float blockSizeFloat = 1.0 + (1.0 - args.strength) * (width / 42);
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


// Grain based on the work by Stefan Gustavson in "Simplex noise demystified"
constant int perm[256] = { 151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
    140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,
    62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,
    168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,
    133,230,220,105,92,41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,
    209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,
    173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,
    206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,
    163,70,221,153,101,155,167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,
    232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,
    241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,
    176,115,121,50,45,127,4,150,254,138,236,205,93,222,114,67,29,24,72,243,141,
    128,195,78,66,215,61,156,180 };

constant float2 grad2[8] = {
    float2(1,1), float2(-1,1), float2(1,-1), float2(-1,-1),
    float2(1,0), float2(-1,0), float2(0,1), float2(0,-1)
};

inline int hash(int i) {
    return perm[i & 255];
}

// Modified 2D simplex noise that takes a time parameter
float snoise(float2 p, float time) {
    // Add time variation to input coordinates
    p += float2(sin(time * 0.1 + p.y), cos(time * 0.1 + p.x)) * 0.5;
    
    float n0, n1, n2;
    const float F2 = 0.366025404f;
    const float G2 = 0.211324865f;
    
    float s = (p.x + p.y) * F2;
    float2 i = floor(p + s);
    float t = (i.x + i.y) * G2;
    float2 p0 = p - (i - t);
    
    float2 i1 = (p0.x > p0.y) ? float2(1, 0) : float2(0, 1);
    float2 p1 = p0 - i1 + G2;
    float2 p2 = p0 - 1.0 + 2.0 * G2;
    
    // Incorporate time into the hash calculation
    int timeHash = hash(int(time * 13.0)) & 255;
    int gi0 = hash(hash(int(i.x) + timeHash) + int(i.y));
    int gi1 = hash(hash(int(i.x) + i1.x + timeHash) + int(i.y) + i1.y);
    int gi2 = hash(hash(int(i.x) + 1 + timeHash) + int(i.y) + 1);
    
    float t0 = 0.5 - p0.x * p0.x - p0.y * p0.y;
    if(t0 < 0) {
        n0 = 0.0;
    } else {
        t0 *= t0;
        n0 = t0 * t0 * dot(grad2[gi0 & 7], p0);
    }
    
    float t1 = 0.5 - p1.x * p1.x - p1.y * p1.y;
    if(t1 < 0) {
        n1 = 0.0;
    } else {
        t1 *= t1;
        n1 = t1 * t1 * dot(grad2[gi1 & 7], p1);
    }
    
    float t2 = 0.5 - p2.x * p2.x - p2.y * p2.y;
    if(t2 < 0) {
        n2 = 0.0;
    } else {
        t2 *= t2;
        n2 = t2 * t2 * dot(grad2[gi2 & 7], p2);
    }
    
    return 70.0 * (n0 + n1 + n2);
}

kernel void grain(constant KernelArguments &args [[buffer(0)]],
                  texture2d<float, access::read_write> yTexture [[texture(0)]],
                  texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    float normalizedStrength = (args.strength + 1.0) * 0.5;
    
    float4 color = yTexture.read(gid);
    float y = color.r;
    
    float2 resolution = float2(yTexture.get_width(), yTexture.get_height());
    float2 uv = float2(gid) / resolution;
    
    float noise = 0.0;
    float frequency = 2.0;
    float amplitude = 1.0;
    // Higher persistence gives more clumping of the grains
    float persistence = mix(0.3, 0.5, normalizedStrength);
    
    // Use frame number directly in noise generation
    float timeValue = float(args.frame) * 0.05;
    
    for (int i = 0; i < 2; i++) { // using 2 octaves
        float2 coord = uv * frequency * resolution * 0.05; // 0.05 makes finer grain than 0.03
        
        // Pass time to noise function
        float n = snoise(coord, timeValue + float(i) * 1.618); // Golden ratio for varied offsets
        
        noise += n * amplitude;
        frequency *= 3.0; // Larger frequency steps
        amplitude *= persistence;
    }
    
    noise = clamp(noise, -1.0, 1.0);
    
    float baseGrainAmount = mix(0.08, 0.02, smoothstep(0.2, 0.8, y));
    float enhancedStrength = pow(abs(normalizedStrength), 0.7) * sign(args.strength);
    float grainAmount = baseGrainAmount * enhancedStrength * 3.0;
    
    float grainStrength = noise * grainAmount;
    if (normalizedStrength > 0.7) {
        grainStrength *= 1.0 + (normalizedStrength - 0.7) * 2.0;
    }
    
    float newY = y * (1.0 + grainStrength);
    newY = clamp(newY, 0.0, 2.0);
    
    yTexture.write(float4(newY, 0, 0, 0), gid);
}

kernel void push(constant KernelArguments &args [[buffer(0)]],
                 texture2d<float, access::read_write> yTexture [[texture(0)]],
                 texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                 uint2 gid [[thread_position_in_grid]]) {

    float4 luma = yTexture.read(gid);
    
    float y = luma.r;
    
    float newY = pow(y, 1.1 + args.strength);
    
    yTexture.write(float4(newY, 0, 0, 0), gid);
    
    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float4 chroma = cbcrTexture.read(cbcrGid);

        float cb = chroma.r;
        float cr = chroma.g;

        float newCb = pow(cb + 0.5, 1 + args.strength) - 0.5;
        float newCr = pow(cr + 0.5, 1 + args.strength) - 0.5;

        cbcrTexture.write(float4(newCb, newCr, 0, 0), cbcrGid);
    }
}

kernel void bleachpass(constant KernelArguments &args [[buffer(0)]],
                       texture2d<float, access::read_write> yTexture [[texture(0)]],
                       texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    float contrast = 1.0 + args.strength * 0.55;
    float bleachY = clamp((y - 0.5) * contrast + 0.5, 0.0, 2.0);
    bleachY = mix(y, bleachY, 0.85);
    yTexture.write(float4(bleachY, 0, 0, 0), gid);

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float2 chroma = cbcrTexture.read(cbcrGid).rg;
        float2 neutral = float2(0.5, 0.5);
        float desaturated = 0.55 + 0.35 * args.strength;
        float2 newChroma = mix(chroma, neutral, desaturated);
        cbcrTexture.write(float4(newChroma, 0, 0), cbcrGid);
    }
}

kernel void chromalag(constant KernelArguments &args [[buffer(0)]],
                      texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        int cbcrWidth = cbcrTexture.get_width();
        int lag = int((2.0 + args.strength * 10.0) * sin(float(args.frame) * 0.08));
        int smear = max(1, int(1.0 + args.strength * 5.0));
        int leftX = clamp(int(cbcrGid.x) - lag, 0, cbcrWidth - 1);
        int rightX = clamp(leftX - smear, 0, cbcrWidth - 1);

        float2 lead = cbcrTexture.read(uint2(leftX, int(cbcrGid.y))).rg;
        float2 trail = cbcrTexture.read(uint2(rightX, int(cbcrGid.y))).rg;
        float2 blended = mix(lead, trail, 0.45 + 0.25 * args.strength);
        cbcrTexture.write(float4(blended, 0, 0), cbcrGid);
    }
}

kernel void splittone(constant KernelArguments &args [[buffer(0)]],
                      texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    float pivot = 0.48;
    float balance = smoothstep(pivot - 0.18, pivot + 0.18, clamp(y, 0.0, 1.0));

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float2 chroma = cbcrTexture.read(cbcrGid).rg;
        float2 shadowTone = float2(0.56, 0.46);
        float2 highlightTone = float2(0.46, 0.57);
        float2 target = mix(shadowTone, highlightTone, balance);
        float2 toned = mix(chroma, target, 0.18 + 0.32 * args.strength);
        cbcrTexture.write(float4(toned, 0, 0), cbcrGid);
    }
}

kernel void scanlines(constant KernelArguments &args [[buffer(0)]],
                      texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    float linePhase = float(gid.y + args.frame) * 0.5;
    float modulation = 0.5 + 0.5 * sin(linePhase * M_PI_F);
    float darkening = (0.08 + 0.24 * args.strength) * modulation;
    float boostedY = y * (1.0 - darkening) + (darkening * 0.03);
    yTexture.write(float4(boostedY, 0, 0, 0), gid);
}

kernel void solarize(constant KernelArguments &args [[buffer(0)]],
                     texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    float threshold = mix(0.7, 0.35, args.strength);
    float inverted = 1.2 - y;
    float blend = smoothstep(threshold - 0.08, threshold + 0.08, clamp(y, 0.0, 1.2));
    float finalY = mix(y, inverted, blend);
    yTexture.write(float4(clamp(finalY, 0.0, 2.0), 0, 0, 0), gid);

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float2 chroma = cbcrTexture.read(cbcrGid).rg;
        float2 invertedChroma = 1.0 - chroma;
        float2 finalChroma = mix(chroma, invertedChroma, blend * (0.4 + 0.4 * args.strength));
        cbcrTexture.write(float4(finalChroma, 0, 0), cbcrGid);
    }
}

kernel void newsprint(constant KernelArguments &args [[buffer(0)]],
                      texture2d<float, access::read_write> yTexture [[texture(0)]],
                      texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {

    float y = clamp(yTexture.read(gid).r, 0.0, 1.0);
    float angle = 0.35;
    float2 centered = float2(gid) - float2(yTexture.get_width(), yTexture.get_height()) * 0.5;
    float2 rotated = float2(
        centered.x * cos(angle) - centered.y * sin(angle),
        centered.x * sin(angle) + centered.y * cos(angle)
    );
    float cellScale = 0.035 + 0.09 * args.strength;
    float pattern = sin(rotated.x * cellScale) * sin(rotated.y * cellScale);
    float ink = smoothstep(-0.15, 0.55, 1.0 - y + pattern * 0.35);
    float finalY = mix(y, ink, 0.65 + 0.25 * args.strength);
    yTexture.write(float4(clamp(finalY, 0.0, 1.0), 0, 0, 0), gid);

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float2 chroma = cbcrTexture.read(cbcrGid).rg;
        float2 desaturated = mix(chroma, float2(0.5, 0.5), 0.75 + 0.2 * args.strength);
        cbcrTexture.write(float4(desaturated, 0, 0), cbcrGid);
    }
}

kernel void halation(constant KernelArguments &args [[buffer(0)]],
                     texture2d<float, access::read_write> yTexture [[texture(0)]],
                     texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {

    float y = yTexture.read(gid).r;
    float highlight = smoothstep(0.62, 1.1, clamp(y, 0.0, 1.5));
    float glow = highlight * (0.06 + 0.16 * args.strength);
    float newY = min(y + glow, 2.0);
    yTexture.write(float4(newY, 0, 0, 0), gid);

    if ((gid.x % args.widthRatio == 0) && (gid.y % args.heightRatio == 0)) {
        uint2 cbcrGid = gid / uint2(args.widthRatio, args.heightRatio);
        float2 chroma = cbcrTexture.read(cbcrGid).rg;
        float2 warmTarget = float2(0.47, 0.57);
        float2 warmed = mix(chroma, warmTarget, glow * 1.6);
        cbcrTexture.write(float4(warmed, 0, 0), cbcrGid);
    }
}


// ----====================== IMPRINTER ======================----

struct ImprintArguments {
    uint offsetX;
    uint offsetY;
    uint widthRatio;
    uint heightRatio;
    uint videoRange;
};

float quantizeImprintSample(float value) {
    // CVPixelBuffer stores ten-bit codes in the high bits of each 16-bit word.
    // Round before storing: leaving fractional codes in the low bits biases
    // the subsequent ten-bit read toward darker values.
    return clamp(round(value * (65535.0 / 64.0)), 0.0, 1023.0) * (64.0 / 65535.0);
}

float imprintHLGDecode(float value) {
    float x = abs(value);
    float linear = x <= 0.5 ? x * x / 3.0
        : (exp((x - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
    return copysign(linear, value);
}

float imprintHLGEncode(float value) {
    float x = abs(value);
    float encoded = x <= 1.0 / 12.0 ? sqrt(3.0 * x)
        : 0.17883277 * log(12.0 * x - 0.28466892) + 0.55991073;
    return copysign(encoded, value);
}

constant float3 imprintLumaWeights = float3(0.2627, 0.6780, 0.0593);

// BT.2100 HLG reference display light: inverse OETF followed by the OOTF.
// Use the fixed 1,000-nit reference's system gamma (1.2), never screen headroom.
// Return light normalized to that reference peak; the web conversion below
// anchors SDR graphics white at 203 nits.
float3 imprintHLGToLight(float3 rgb) {
    float3 scene = float3(imprintHLGDecode(rgb.r), imprintHLGDecode(rgb.g), imprintHLGDecode(rgb.b));
    return scene * pow(max(abs(dot(scene, imprintLumaWeights)), 1e-12), 0.2);
}

float3 imprintLightToHLG(float3 light) {
    float3 scene = light * pow(max(abs(dot(light, imprintLumaWeights)), 1e-12), 1.0 / 1.2 - 1.0);
    return float3(imprintHLGEncode(scene.r), imprintHLGEncode(scene.g), imprintHLGEncode(scene.b));
}

float imprintSRGBEncode(float value) {
    float x = abs(value);
    return copysign(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055, value);
}

float imprintSRGBDecode(float value) {
    float x = abs(value);
    return copysign(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4), value);
}

// Evaluate web-style source-over in extended sRGB. These are only temporary
// shader values: negative and above-white components remain unclipped, and
// the camera buffer itself stays HLG/BT.2020. 203 nits anchors graphics white.
float3 imprintHLGToWebRGB(float3 rgb) {
    float3 light = imprintHLGToLight(rgb) * (1000.0 / 203.0);
    float3 srgb = float3(
        dot(light, float3(1.660491002, -0.587641139, -0.072849863)),
        dot(light, float3(-0.124550475, 1.132899897, -0.008349423)),
        dot(light, float3(-0.018150763, -0.100578898, 1.118729661)));
    return float3(imprintSRGBEncode(srgb.r), imprintSRGBEncode(srgb.g), imprintSRGBEncode(srgb.b));
}

float3 imprintWebRGBToHLG(float3 rgb) {
    float3 srgb = float3(imprintSRGBDecode(rgb.r), imprintSRGBDecode(rgb.g), imprintSRGBDecode(rgb.b));
    float3 light = float3(
        dot(srgb, float3(0.627403896, 0.329283038, 0.043313066)),
        dot(srgb, float3(0.069097289, 0.919540395, 0.011362316)),
        dot(srgb, float3(0.016391439, 0.088013308, 0.895595253)));
    return imprintLightToHLG(light * (203.0 / 1000.0));
}

kernel void imprint(constant ImprintArguments &args [[buffer(0)]],
                    texture2d<float, access::read_write> yTexture [[texture(0)]],
                    texture2d<float, access::read_write> cbcrTexture [[texture(1)]],
                    texture2d<float, access::read> overlayTexture [[texture(2)]],
                    uint2 gid [[thread_position_in_grid]]) {
    uint2 origin = uint2(args.offsetX, args.offsetY) + gid;
    uint2 ratio = uint2(args.widthRatio, args.heightRatio);
    // One invocation owns every luma sample sharing this chroma sample. This
    // prevents in-place RGB reconstruction from reading another thread's edits.
    if (any(origin % ratio != uint2(0))) return;
    uint2 size = uint2(yTexture.get_width(), yTexture.get_height());
    if (any(origin >= size)) return;

    float lumaScale = (args.videoRange ? 876.0 : 1023.0) * (64.0 / 65535.0);
    float lumaOffset = args.videoRange ? (64.0 * 64.0 / 65535.0) : 0.0;
    float chromaScale = (args.videoRange ? 896.0 : 1022.0) * (64.0 / 65535.0);
    float chromaCenter = 512.0 * 64.0 / 65535.0;
    uint2 cbcrPos = origin / ratio;
    float2 originalChroma = cbcrTexture.read(cbcrPos).rg;
    float2 chroma = (originalChroma - chromaCenter) / chromaScale;
    float2 chromaDelta = 0;
    bool changed = false;
    uint count = 0;
    for (uint dy = 0; dy < ratio.y && origin.y + dy < size.y; ++dy) {
        for (uint dx = 0; dx < ratio.x && origin.x + dx < size.x; ++dx) {
            ++count;
            uint2 pos = origin + uint2(dx, dy);
            if (pos.x >= overlayTexture.get_width() || pos.y >= overlayTexture.get_height()) continue;
            float4 overlay = overlayTexture.read(pos);
            float alpha = overlay.a;
            if (alpha == 0) continue; // Preserve the original luma word exactly.

            float3 result = overlay.rgb;
            if (alpha < 1) {
                float y = (yTexture.read(pos).r - lumaOffset) / lumaScale;
                float r = y + 1.4746 * chroma.y;
                float b = y + 1.8814 * chroma.x;
                float g = (y - 0.2627 * r - 0.0593 * b) / 0.6780;
                // Unpremultiply before color conversion. Apply alpha once in
                // the web compositing space; alpha has no gamma adjustment.
                float3 foreground = imprintHLGToWebRGB(overlay.rgb / alpha);
                float3 background = imprintHLGToWebRGB(float3(r, g, b));
                result = imprintWebRGBToHLG(alpha * foreground + (1.0 - alpha) * background);
            }
            float resultY = dot(result, imprintLumaWeights);
            yTexture.write(quantizeImprintSample(resultY * lumaScale + lumaOffset), pos);
            float2 resultChroma = float2((result.b - resultY) / 1.8814, (result.r - resultY) / 1.4746);
            chromaDelta += resultChroma - chroma;
            changed = true;
        }
    }
    if (changed) {
        // Average only the changes into the shared sample. An uncovered block
        // is never rewritten; uncovered luma within a boundary block is retained.
        float2 result = originalChroma + chromaDelta * (chromaScale / float(count));
        cbcrTexture.write(float4(
            quantizeImprintSample(result.x), quantizeImprintSample(result.y), 0, 0), cbcrPos);
    }
}

// ----================== OUTPUT PRESENTATION ==================----
// Read the finished camera buffer; only write the separate display drawable.
struct OutputPreviewArguments {
    float lumaOffset;
    float lumaRange;
    float chromaRange;
    float headroom;
    float2 chromaOffset;
};

struct OutputPreviewVertex {
    float4 position [[position]];
    float2 uv;
};

vertex OutputPreviewVertex outputPreviewVertex(uint index [[vertex_id]]) {
    const float2 positions[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 p = positions[index];
    return { float4(p, 0, 1), float2((p.x + 1) / 2, (1 - p.y) / 2) };
}

fragment float4 outputPreviewFragment(
    OutputPreviewVertex in [[stage_in]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    constant OutputPreviewArguments &args [[buffer(0)]]) {
    constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = (luma.sample(sample, in.uv).r * (65535.0 / 64.0) - args.lumaOffset) / args.lumaRange;
    float2 cbcr = (chroma.sample(sample, in.uv + args.chromaOffset).rg * (65535.0 / 64.0) - 512.0) / args.chromaRange;
    float r = y + 1.4746 * cbcr.y;
    float b = y + 1.8814 * cbcr.x;
    float g = (y - 0.2627 * r - 0.0593 * b) / 0.6780;

    // The same fixed HLG reference used by the compositor, now expressed as
    // linear BT.2020 EDR. 203-nit graphics white becomes ordinary UI white (1).
    // The layer is linear with toneMapMode = .never: no second HLG tone map.
    const float referencePeak = 1000.0 / 203.0;
    float3 light = imprintHLGToLight(float3(r, g, b)) * referencePeak;
    float peak = max(light.r, max(light.g, light.b));
    if (peak > 1.0) {
        float limit = max(args.headroom, 1.0);
        float mappedPeak = min(peak, limit);
        if (limit > 1.0 && limit < referencePeak) {
            // Preserve SDR values and the slope at white. Compress only HDR
            // highlights, mapping the reference peak to the available peak.
            float compression = 1.0 / (limit - 1.0) - 1.0 / (referencePeak - 1.0);
            mappedPeak = min(1.0 + (peak - 1.0) / (1.0 + compression * (peak - 1.0)), limit);
        }
        light *= mappedPeak / peak;
    }
    return float4(light, 1);
}
