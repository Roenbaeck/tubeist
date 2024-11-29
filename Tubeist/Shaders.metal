#include <metal_stdlib>
using namespace metal;

kernel void overlayShader(texture2d<half, access::read_write> videoY [[ texture(0) ]],
                          texture2d<half, access::read_write> videoUV [[ texture(1) ]],
                          texture2d<half, access::read> overlay [[ texture(2) ]],
                          uint2 gid [[ thread_position_in_grid ]]) {
    if (gid.x >= videoY.get_width() || gid.y >= videoY.get_height()) return;


    half4 bgra = overlay.read(gid);
    if (bgra.a == 0.0) return;
    
    half3 rgb = half3(bgra.r, bgra.g, bgra.b);
    
    // Conversion Matrix from RGB to YUV (BT.2020, Limited Range)
    half3x3 rgbToYuv2020Limited = half3x3(
                                          0.2627,  0.6780,  0.0593,
                                          -0.13963, -0.36037,  0.500,
                                          0.500, -0.45979, -0.04021
                                          );
    
    half3 yuv = rgb * rgbToYuv2020Limited;
    
    // Adjust for subsampled UV plane
    uint2 uvCoord = uint2(gid.x / 2, gid.y / 2);
    
    videoY.write(yuv.r, gid);
    videoUV.write(half4(yuv.g, yuv.b, 0.0, 0.0), uvCoord);
}

kernel void testShader(texture2d<half, access::read_write> videoY [[ texture(0) ]],
                          texture2d<half, access::read_write> videoUV [[ texture(1) ]],
                          texture2d<half, access::read> overlay [[ texture(2) ]],
                          uint2 gid [[ thread_position_in_grid ]]) {
    if (gid.x >= videoY.get_width() || gid.y >= videoY.get_height()) return;
    
    // Write white on even x-coordinates and black on odd x-coordinates
    half color = (gid.x % 2 == 0) ? half(1.0) : half(0.0);

    // Write to Y texture
    videoY.write(color, gid);
    
    // Adjust for subsampled UV plane
    uint2 uvCoord = uint2(gid.x / 2, gid.y / 2);
    
    // Write to UV texture (using same color for simplicity)
    videoUV.write(half4(color, color, 0.0, 0.0), uvCoord);
}
