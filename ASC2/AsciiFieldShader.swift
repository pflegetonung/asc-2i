/// Исходник шейдеров ASCII-поля. Компилируется в рантайме (`MTLDevice.makeLibrary(source:)`),
/// поэтому для сборки не нужен отдельно скачиваемый Metal Toolchain.
enum AsciiFieldShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

/// Раскладка совпадает с `AsciiFieldRenderer.Uniforms` в Swift. Все размеры — в пикселях drawable.
struct FieldUniforms {
    float2 viewSize;
    float2 origin;        // левый верхний угол клетки (0, 0)
    float cellSize;
    float time;
    float maxOpacity;
    float opacityLevels;
    float4 glyphColor;
    uint4 tierCounts;     // сколько символов в каждом ярусе атласа
    uint columns;
    uint rows;
    uint atlasColumns;
    uint atlasRows;
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

/// Псевдослучайное число в [0, 1) для целочисленной точки.
static float hash(int x, int y, int z) {
    uint h = mix32(uint(x) ^ 0xC1F0D11u);
    h = mix32(h ^ uint(y) * 0x9E3779B1u);
    h = mix32(h ^ uint(z) * 0x85EBCA77u);
    return float(h >> 8) * (1.0 / 16777216.0);
}

/// 3D value-noise: значения в узлах решётки из хеша, между ними — сглаженная интерполяция.
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

/// Фрактальный шум из трёх октав, растянутый обратно к [0, 1]
/// (сумма октав иначе жмётся к 0.5, и пятна получаются блёклыми).
static float fbm(float3 p) {
    float sum = 0, amplitude = 0.5, frequency = 1, norm = 0;
    for (int octave = 0; octave < 3; octave++) {
        // Сдвиг на октаву, чтобы узлы решёток разных октав не совпадали в начале координат.
        float offset = float(octave) * 17.31;
        sum += amplitude * valueNoise(p * frequency + float3(offset, -offset, offset));
        norm += amplitude;
        amplitude *= 0.5;
        frequency *= 2;
    }
    return saturate((sum / norm - 0.5) * 1.7 + 0.5);
}

/// Один инстанс — одна клетка сетки (четыре вершины triangle strip).
/// Символы не двигаются: «плавание» — это медленно меняющаяся яркость (3D-шум по x, y, времени),
/// а сами символы время от времени случайно заменяются на другие.
vertex CellOut cellVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant FieldUniforms &u [[buffer(0)]]) {
    CellOut out;
    int column = int(iid % u.columns);
    int row = int(iid / u.columns);

    float n = fbm(float3(float(column) * 0.085, float(row) * 0.085, u.time * 0.05));
    // Пятна: всё ниже 0.42 почти гаснет, выше 0.78 — максимум.
    float blob = smoothstep(0.42, 0.78, n);
    // Статичный разброс яркости между соседями, чтобы пятна не выглядели «плоскими».
    float jitter = 0.8 + 0.2 * hash(column, row, -1);
    float intensity = (0.08 + 0.92 * blob) * jitter;

    int level = min(int(u.opacityLevels) - 1, int(intensity * u.opacityLevels));
    if (level <= 0) {
        // Вырожденный квад за пределами экрана — клетка не рисуется.
        out.position = float4(2, 2, 0, 1);
        out.uv = 0;
        out.opacity = 0;
        return out;
    }

    // Каждая клетка меняет символ в своём ритме: период 2–8 с со своим сдвигом фазы.
    float period = 2 + 6 * hash(column, row, -2);
    float phase = hash(column, row, -3);
    int epoch = int(floor(u.time / period + phase));
    uint tier = min(u.atlasRows - 1, uint(blob * float(u.atlasRows)));
    uint count = u.tierCounts[tier];
    uint glyph = uint(hash(column, row, epoch) * float(count)) % count;

    float2 corner = float2(vid & 1, vid >> 1);
    float2 p = u.origin + (float2(column, row) + corner) * u.cellSize;
    out.position = float4(p.x / u.viewSize.x * 2 - 1, 1 - p.y / u.viewSize.y * 2, 0, 1);
    out.uv = (float2(glyph, tier) + corner) / float2(u.atlasColumns, u.atlasRows);
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
