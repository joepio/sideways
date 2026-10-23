// Temporal anti-aliasing. Every frame the projection is shifted by a
// sub-pixel Halton offset; this pass reprojects last frame's result onto
// this frame's pixels and blends the two. Over a few frames each pixel
// becomes the average of many sample positions: smooth edges on geometry
// and on alpha-tested needles alike. Ghosting is held back by clipping the
// history to the colour range of the current 3x3 neighbourhood (variance
// clipping, Salvi 2016), done in YCoCg of range-compressed colour.

struct Taa {
    inv_view_proj: mat4x4<f32>,  // this frame, jittered: pixel centre to world
    prev_view_proj: mat4x4<f32>, // last frame, without jitter
    size: vec4<f32>,             // w, h, 1/w, 1/h
    params: vec4<f32>,           // exposure, minimum blend, 1: reset history, clip gamma
};

@group(0) @binding(0) var cur: texture_2d<f32>;
@group(0) @binding(1) var depth_tex: texture_depth_2d;
@group(0) @binding(2) var hist: texture_2d<f32>;
@group(0) @binding(3) var out_tex: texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var<uniform> taa: Taa;
@group(0) @binding(5) var lin: sampler;

fn luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// Exposed and range-compressed (Karis): bright pixels do not dominate.
fn compress(c: vec3<f32>) -> vec3<f32> {
    let x = max(c, vec3<f32>(0.0)) * taa.params.x;
    return x / (1.0 + luma(x));
}

fn expand(x: vec3<f32>) -> vec3<f32> {
    return x / max(1.0 - luma(x), 1e-4) / taa.params.x;
}

fn ycocg(c: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

fn rgb(y: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z);
}

// Catmull-Rom through 5 bilinear taps: history stays sharp when it moves.
fn history(uv: vec2<f32>) -> vec3<f32> {
    let pos = uv * taa.size.xy;
    let c = floor(pos - 0.5) + 0.5;
    let f = pos - c;
    let w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    let w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    let w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    let w3 = f * f * (-0.5 + 0.5 * f);
    let w12 = w1 + w2;
    let t0 = (c - 1.0) * taa.size.zw;
    let t3 = (c + 2.0) * taa.size.zw;
    let t12 = (c + w2 / w12) * taa.size.zw;
    var s = textureSampleLevel(hist, lin, vec2<f32>(t12.x, t0.y), 0.0).rgb * (w12.x * w0.y);
    s += textureSampleLevel(hist, lin, vec2<f32>(t0.x, t12.y), 0.0).rgb * (w0.x * w12.y);
    s += textureSampleLevel(hist, lin, t12, 0.0).rgb * (w12.x * w12.y);
    s += textureSampleLevel(hist, lin, vec2<f32>(t3.x, t12.y), 0.0).rgb * (w3.x * w12.y);
    s += textureSampleLevel(hist, lin, vec2<f32>(t12.x, t3.y), 0.0).rgb * (w12.x * w3.y);
    let wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(s / wsum, vec3<f32>(0.0));
}

// Pull `h` towards the box centre until it lies inside (Playdead).
fn clip_box(h: vec3<f32>, lo: vec3<f32>, hi: vec3<f32>) -> vec3<f32> {
    let centre = 0.5 * (hi + lo);
    let extent = 0.5 * (hi - lo) + 1e-5;
    let v = h - centre;
    let a = abs(v / extent);
    let m = max(a.x, max(a.y, a.z));
    return select(h, centre + v / m, m > 1.0);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<i32>(taa.size.xy);
    let px = vec2<i32>(gid.xy);
    if px.x >= size.x || px.y >= size.y {
        return;
    }
    let c = compress(textureLoad(cur, px, 0).rgb);
    // Neighbourhood statistics, and the nearest surface around (edges of
    // moving geometry reproject with the foreground).
    var m1 = vec3<f32>(0.0);
    var m2 = vec3<f32>(0.0);
    var best = px;
    var best_d = -1.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let q = clamp(px + vec2<i32>(x, y), vec2<i32>(0), size - 1);
            let s = ycocg(compress(textureLoad(cur, q, 0).rgb));
            m1 += s;
            m2 += s * s;
            let d = textureLoad(depth_tex, q, 0);
            if d > best_d {
                best_d = d;
                best = q;
            }
        }
    }
    let mean = m1 / 9.0;
    let sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3<f32>(0.0)));
    // Where that surface was last frame. Sky (depth 0) is a direction:
    // w = 0 keeps it at infinity through both matrices.
    let ndc = vec2<f32>((f32(best.x) + 0.5) * taa.size.z * 2.0 - 1.0, 1.0 - (f32(best.y) + 0.5) * taa.size.w * 2.0);
    let world = taa.inv_view_proj * vec4<f32>(ndc, best_d, 1.0);
    let prev = taa.prev_view_proj * world;
    let prev_ndc = prev.xy / prev.w;
    let off = vec2<f32>(best - px);
    let prev_uv = vec2<f32>(prev_ndc.x * 0.5 + 0.5, 0.5 - prev_ndc.y * 0.5) - off * taa.size.zw;
    let uv = (vec2<f32>(px) + 0.5) * taa.size.zw;
    let motion = length((prev_uv - uv) * taa.size.xy);
    let inside = all(prev_uv >= vec2<f32>(0.0)) && all(prev_uv <= vec2<f32>(1.0)) && prev.w > 0.0;
    var n = 0.0;
    var result = c;
    if inside && taa.params.z < 0.5 {
        n = textureSampleLevel(hist, lin, prev_uv, 0.0).a;
        // A still image can trust its history more than a moving one.
        let gamma = mix(taa.params.w, 1.0, smoothstep(0.05, 0.5, motion));
        let h = ycocg(compress(history(prev_uv)));
        let clipped = clip_box(h, mean - gamma * sigma, mean + gamma * sigma);
        // History that had to be pulled far was wrong: start counting again.
        let pulled = length(clipped - h) / (length(sigma) + 1e-3);
        n = select(n, min(n, 2.0), pulled > 1.0);
        let alpha = max(1.0 / (n + 1.0), taa.params.y);
        result = mix(rgb(clipped), c, alpha);
    }
    textureStore(out_tex, px, vec4<f32>(expand(result), min(n + 1.0, 255.0)));
}
