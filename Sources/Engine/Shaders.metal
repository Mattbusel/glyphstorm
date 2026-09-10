#include <metal_stdlib>
using namespace metal;

// One glyph. Must match `GlyphInstance` in GlyphField.swift field for field,
// including the implicit padding before `color`, which Metal aligns to 16 and
// Swift's SIMD4<Float> aligns to 16 as well. Both come to 32 bytes a glyph.
struct GlyphInstance {
    float2 position;   // centre, in view points, y down
    float  size;       // cell height in points
    float  glyph;      // index into the atlas, in ramp order
    float4 color;
};

// Must match `FieldUniforms` in GlyphField.swift. 32 bytes.
struct FieldUniforms {
    float2 viewport;      // drawable size in points
    float2 atlasCell;     // size of one atlas cell in uv
    float  atlasColumns;  // cells across the atlas
    float  pad0;
    float2 pad1;
};

struct Varying {
    float4 clip [[position]];
    float2 uv;
    float4 tint;
};

// The six corners of a quad, as two triangles. Cheaper than an index buffer for
// something this small, and it keeps the whole draw to one call with no vertex
// buffer at all: every glyph is built from its instance data alone.
constant float2 kCorners[6] = {
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)
};

vertex Varying glyph_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device GlyphInstance *glyphs [[buffer(0)]],
                            constant FieldUniforms &u [[buffer(1)]])
{
    GlyphInstance g = glyphs[iid];
    float2 corner = kCorners[vid];

    // A glyph cell is taller than wide; the atlas cell is square, so the quad
    // is drawn square and the *grid* does the narrowing. Drawing a narrow quad
    // instead would squash the letterform itself.
    float half = g.size * 0.5;
    float2 pointPos = g.position + (corner - 0.5) * (half * 2.0);

    // View points to clip space. y is flipped because UIKit's origin is top
    // left and Metal's clip space has y up.
    float2 ndc = float2(
        (pointPos.x / max(u.viewport.x, 1.0)) * 2.0 - 1.0,
        1.0 - (pointPos.y / max(u.viewport.y, 1.0)) * 2.0
    );

    // Which cell of the atlas this character lives in.
    float col = fmod(g.glyph, u.atlasColumns);
    float row = floor(g.glyph / u.atlasColumns);

    Varying out;
    out.clip = float4(ndc, 0.0, 1.0);
    out.uv = (float2(col, row) + corner) * u.atlasCell;
    out.tint = g.color;
    return out;
}

fragment float4 glyph_fragment(Varying in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]],
                               sampler samp [[sampler(0)]])
{
    // The atlas is white glyphs on transparent, so alpha is the coverage and
    // the colour comes entirely from the instance. That is what lets one
    // texture serve every palette.
    float coverage = atlas.sample(samp, in.uv).a;

    // Premultiplied out, to match the pipeline's blend factors. Blending
    // straight alpha here would fringe every glyph dark against the ground.
    float a = coverage * in.tint.a;
    return float4(in.tint.rgb * a, a);
}
