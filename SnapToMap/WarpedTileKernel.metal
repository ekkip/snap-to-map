#include <metal_stdlib>
using namespace metal;

struct TileUniforms
{
    uint2 outputSize;
    float2 sourceSize;
    float2 destOrigin;
    float2 destStepX;
    float2 destStepY;
    float3x3 destToSource;
    float4 backgroundColor;
    float mipLevel;
};

static inline float2 applyHomography(float3x3 m, float2 p)
{
    float3 q = m * float3(p.x, p.y, 1.0);
    return q.xy / q.z;
}

kernel void renderWarpedTile(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::write>  outputTexture [[texture(1)]],
    constant TileUniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.outputSize.x || gid.y >= uniforms.outputSize.y) {
        return;
    }

    float2 destCoord =
        uniforms.destOrigin
      + float(gid.x) * uniforms.destStepX
      + float(gid.y) * uniforms.destStepY;

    float2 sourcePixel = applyHomography(uniforms.destToSource, destCoord);

    if (sourcePixel.x < 0.0 ||
        sourcePixel.y < 0.0 ||
        sourcePixel.x >= uniforms.sourceSize.x ||
        sourcePixel.y >= uniforms.sourceSize.y) {
        outputTexture.write(uniforms.backgroundColor, gid);
        return;
    }

    constexpr sampler sourceSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );

    float2 uv = (sourcePixel + 0.5) / uniforms.sourceSize;
    float4 color = sourceTexture.sample(sourceSampler, uv, level(uniforms.mipLevel));

    outputTexture.write(color, gid);
}
