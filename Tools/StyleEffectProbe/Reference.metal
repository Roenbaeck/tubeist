// Frozen pre-optimization kernels for output comparison and timing.
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
