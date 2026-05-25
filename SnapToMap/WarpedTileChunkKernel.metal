#include <metal_stdlib>
using namespace metal;

struct TileChunkUniforms
{
    uint2 outputSize;

    // Full original source image size in pixels.
    float2 sourceSize;

    // Current chunk origin and size in full-resolution source pixel coordinates.
    float2 chunkOrigin;
    float2 chunkSize;

    // Destination coordinate of output pixel (0,0).
    float2 destOrigin;

    // Destination-space basis vectors per output pixel.
    float2 destStepX;
    float2 destStepY;

    // Inverse transform from destination/warped space to global source pixel space.
    float3x3 destToSource;

    // Background color used only if this shader is responsible for clearing.
    float4 backgroundColor;

    // Source chunk mip level.
    float mipLevel;

    // If true, pixels outside this chunk are written as background.
    // If false, pixels outside this chunk are left unchanged.
    uint clearOutsideChunk;
};

static inline float2 applyHomography(float3x3 m, float2 p)
{
    float3 q = m * float3(p.x, p.y, 1.0);
    return q.xy / q.z;
}

kernel void renderWarpedTileChunk(
    texture2d<float, access::sample> chunkTexture [[texture(0)]],
    texture2d<float, access::read_write> outputTexture [[texture(1)]],
    constant TileChunkUniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.outputSize.x || gid.y >= uniforms.outputSize.y) {
        return;
    }

    float2 destCoord =
        uniforms.destOrigin
      + float(gid.x) * uniforms.destStepX
      + float(gid.y) * uniforms.destStepY;

    // Global source pixel coordinate at mip level 0.
    float2 sourcePixel = applyHomography(uniforms.destToSource, destCoord);

    bool insideSource =
        sourcePixel.x >= 0.0 &&
        sourcePixel.y >= 0.0 &&
        sourcePixel.x < uniforms.sourceSize.x &&
        sourcePixel.y < uniforms.sourceSize.y;

    bool insideChunk =
        sourcePixel.x >= uniforms.chunkOrigin.x &&
        sourcePixel.y >= uniforms.chunkOrigin.y &&
        sourcePixel.x < uniforms.chunkOrigin.x + uniforms.chunkSize.x &&
        sourcePixel.y < uniforms.chunkOrigin.y + uniforms.chunkSize.y;

    if (!insideSource || !insideChunk) {
        if (uniforms.clearOutsideChunk != 0) {
            outputTexture.write(uniforms.backgroundColor, gid);
        }
        return;
    }

    float2 chunkPixel = sourcePixel - uniforms.chunkOrigin;

    constexpr sampler sourceSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );

    float2 uv = (chunkPixel + 0.5) / uniforms.chunkSize;

    float4 color = chunkTexture.sample(
        sourceSampler,
        uv,
        level(uniforms.mipLevel)
    );

    outputTexture.write(color, gid);
}
