/// Shader source for the ASCII field. Compiled at runtime (`MTLDevice.makeLibrary(source:)`),
/// so building doesn't require the separately downloaded Metal Toolchain.
enum AsciiFieldShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

/// Layout matches `AsciiFieldRenderer.Uniforms` in Swift. All sizes are in drawable pixels.
struct FieldUniforms {
    float2 viewSize;
    float2 origin;        // top-left corner of cell (0, 0)
    float cellSize;
    float time;
    float maxOpacity;
    float opacityLevels;
    float4 glyphColor;
    uint4 tierCounts;     // number of glyphs in each clouds tier
    uint columns;
    uint rows;
    uint atlasColumns;
    uint atlasRows;
    uint pattern;         // 0: clouds, 1: image
    uint rampCount;       // glyphs in the weight ramp (the atlas row after the tiers)
    uint tierRows;        // atlas rows taken by the clouds tiers
    uint padding;
};

struct CellOut {
    float4 position [[position]];
    float2 uv;
    float opacity [[flat]];
};

static uint mix32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

/// Pseudo-random number in [0, 1) for an integer point.
static float hash(int x, int y, int z) {
    uint h = mix32(uint(x) ^ 0xC1F0D11u);
    h = mix32(h ^ uint(y) * 0x9E3779B1u);
    h = mix32(h ^ uint(z) * 0x85EBCA77u);
    return float(h >> 8) * (1.0 / 16777216.0);
}

/// 3D value noise: lattice values come from the hash, with smooth interpolation in between.
static float valueNoise(float3 p) {
    float3 f = floor(p);
    int3 i = int3(f);
    float3 t = p - f;
    t = t * t * (3.0 - 2.0 * t);

    float x00 = mix(hash(i.x, i.y,     i.z),     hash(i.x + 1, i.y,     i.z),     t.x);
    float x10 = mix(hash(i.x, i.y + 1, i.z),     hash(i.x + 1, i.y + 1, i.z),     t.x);
    float x01 = mix(hash(i.x, i.y,     i.z + 1), hash(i.x + 1, i.y,     i.z + 1), t.x);
    float x11 = mix(hash(i.x, i.y + 1, i.z + 1), hash(i.x + 1, i.y + 1, i.z + 1), t.x);
    return mix(mix(x00, x10, t.y), mix(x01, x11, t.y), t.z);
}

/// Three-octave fractal noise, stretched back to [0, 1]
/// (otherwise the octave sum clusters around 0.5 and the blobs look washed out).
static float fbm(float3 p) {
    float sum = 0, amplitude = 0.5, frequency = 1, norm = 0;
    for (int octave = 0; octave < 3; octave++) {
        // Per-octave offset so lattices of different octaves don't line up at the origin.
        float offset = float(octave) * 17.31;
        sum += amplitude * valueNoise(p * frequency + float3(offset, -offset, offset));
        norm += amplitude;
        amplitude *= 0.5;
        frequency *= 2;
    }
    return saturate((sum / norm - 0.5) * 1.7 + 0.5);
}

/// One instance per grid cell (four triangle strip vertices).
/// Glyphs never move. With clouds, the "drift" is slowly changing brightness (3D noise over x, y and time);
/// with an image, brightness comes from the picture. Either way each glyph is randomly swapped
/// for another from time to time.
vertex CellOut cellVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant FieldUniforms &u [[buffer(0)]],
                          texture2d<float, access::read> brightness [[texture(0)]]) {
    CellOut out;
    int column = int(iid % u.columns);
    int row = int(iid / u.columns);

    // Each cell swaps its glyph at its own pace: a 2–8 s period with its own phase offset.
    float period = 2 + 6 * hash(column, row, -2);
    float phase = hash(column, row, -3);
    int epoch = int(floor(u.time / period + phase));
    float pick = hash(column, row, epoch);

    float intensity;
    uint2 slot;  // atlas column and row
    if (u.pattern == 1) {
        intensity = brightness.read(uint2(column, row)).r;
        // The ramp is sorted by ink coverage: swap only between the glyph whose weight matches
        // the brightness and its two neighbors of nearly the same weight.
        int center = int(round(intensity * float(u.rampCount - 1)));
        int index = clamp(center + int(pick * 3) - 1, 0, int(u.rampCount) - 1);
        slot = uint2(index, u.tierRows);
    } else {
        float n = fbm(float3(float(column) * 0.085, float(row) * 0.085, u.time * 0.05));
        // Blobs: anything below 0.42 nearly fades out, above 0.78 is full brightness.
        float blob = smoothstep(0.42, 0.78, n);
        // Static brightness variation between neighbors so blobs don't look flat.
        float jitter = 0.8 + 0.2 * hash(column, row, -1);
        intensity = (0.08 + 0.92 * blob) * jitter;
        uint tier = min(u.tierRows - 1, uint(blob * float(u.tierRows)));
        uint count = u.tierCounts[tier];
        slot = uint2(uint(pick * float(count)) % count, tier);
    }

    int level = min(int(u.opacityLevels) - 1, int(intensity * u.opacityLevels));
    if (level <= 0) {
        // Degenerate off-screen quad: the cell is not drawn.
        out.position = float4(2, 2, 0, 1);
        out.uv = 0;
        out.opacity = 0;
        return out;
    }

    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = u.origin + (float2(column, row) + corner) * u.cellSize;
    out.position = float4(p.x / u.viewSize.x * 2 - 1, 1 - p.y / u.viewSize.y * 2, 0, 1);
    out.uv = (float2(slot) + corner) / float2(u.atlasColumns, u.atlasRows);
    out.opacity = u.maxOpacity * float(level) / (u.opacityLevels - 1);
    return out;
}

fragment float4 cellFragment(CellOut in [[stage_in]],
                             texture2d<float> atlas [[texture(0)]],
                             constant FieldUniforms &u [[buffer(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float alpha = atlas.sample(linear, in.uv).r * in.opacity;
    return float4(u.glyphColor.rgb * alpha, alpha);
}
"""#
}
