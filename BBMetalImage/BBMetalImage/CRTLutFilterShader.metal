#include <metal_stdlib>
using namespace metal;

#import "CRTShaderTypes.h"

kernel void
lutFilterKernel(texture2d<half, access::read> inputTexture [[texture(CRTTextureIndexInput)]],
                     texture2d<half, access::write> outputTexture [[texture(CRTTextureIndexOutput)]],
                     texture2d<half, access::sample> lookupTexture [[texture(CRTTextureIndexLut)]],
                     constant float *intensity [[buffer(CRTBufferIndexIntensity)]],
                     constant float *grain [[buffer(CRTBufferIndexGrain)]],
                     constant float *vignette [[buffer(CRTBufferIndexVignette)]],
                     uint2 gid [[thread_position_in_grid]])
{
    // Don't read or write outside of the texture.
    if ((gid.x >= outputTexture.get_width()) || (gid.y >= outputTexture.get_height())) {
        return;
    }

    const half4 base = inputTexture.read(gid);

    if (is_null_texture(lookupTexture)) {
        outputTexture.write(base, gid);
        return;
    }

    const half blueColor = base.b * 63.0h;

    half2 quad1;
    quad1.y = floor(floor(blueColor) / 8.0h);
    quad1.x = floor(blueColor) - (quad1.y * 8.0h);

    half2 quad2;
    quad2.y = floor(ceil(blueColor) / 8.0h);
    quad2.x = ceil(blueColor) - (quad2.y * 8.0h);

    const float A = 0.125;
    const float B = 0.5 / 512.0;
    const float C = 0.125 - 1.0 / 512.0;

    float2 texPos1;
    texPos1.x = A * quad1.x + B + C * base.r;
    texPos1.y = A * quad1.y + B + C * base.g;

    float2 texPos2;
    texPos2.x = A * quad2.x + B + C * base.r;
    texPos2.y = A * quad2.y + B + C * base.g;

    constexpr sampler quadSampler(mag_filter::linear, min_filter::linear);
    const half4 newColor1 = lookupTexture.sample(quadSampler, texPos1);
    const half4 newColor2 = lookupTexture.sample(quadSampler, texPos2);

    const half4 newColor = mix(newColor1, newColor2, fract(blueColor));
    half4 outColor(mix(base, half4(newColor.rgb, base.a), half(*intensity)));

    if (half(*grain) != 0) {
        float grainA = 12.9898;
        float grainB = 78.233;
        float grainC = 43758.5453;
        float grainDt = dot(float2(gid.x, gid.y), float2(grainA, grainB));
        float grainSn = grainDt - 3.14 * floor(grainDt / 3.14); // modulo op
        float grainNoise = fract(sin(grainSn) * grainC);
        outColor = outColor - grainNoise * half(*grain) * half(*intensity);
    }

    if (half(*vignette) != 0) {
        float vignetteDiff = (1.0 - half(*vignette) * half(*intensity)) - distance(float2(float(gid.x) / inputTexture.get_width(), float(gid.y) / inputTexture.get_height()), float2(0.5, 0.5));
        const half vignettePercent = smoothstep(-0.5, 0.5, vignetteDiff);
        outColor = half4(outColor.r * vignettePercent, outColor.g * vignettePercent, outColor.b * vignettePercent, outColor.a * vignettePercent);
    }

    outputTexture.write(outColor, gid);
}
