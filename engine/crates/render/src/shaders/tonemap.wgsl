// Physical exposure, then AgX (Troy Sobotka's view transform, polynomial
// fit), then sRGB encoding into an 8-bit image.

struct Tone {
    exposure: f32,  // 1 / (1.2 * 2^EV100)
    contrast: f32,
    saturation: f32,
    pad: f32,
};

@group(0) @binding(0) var hdr: texture_2d<f32>;
@group(0) @binding(1) var ldr: texture_storage_2d<rgba8unorm, write>;
@group(0) @binding(2) var<uniform> tone: Tone;

fn agx_contrast(x: vec3<f32>) -> vec3<f32> {
    let x2 = x * x;
    let x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

fn agx(c: vec3<f32>) -> vec3<f32> {
    let m = mat3x3<f32>(
        vec3<f32>(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
        vec3<f32>(0.0784335999999992, 0.878468636469772, 0.0784336),
        vec3<f32>(0.0792237451477643, 0.0791661274605434, 0.879142973793104),
    );
    let min_ev = -12.47393;
    let max_ev = 4.026069;
    var v = m * c;
    v = clamp(log2(max(v, vec3<f32>(1e-10))), vec3<f32>(min_ev), vec3<f32>(max_ev));
    v = (v - min_ev) / (max_ev - min_ev);
    return agx_contrast(v);
}

fn agx_eotf(v: vec3<f32>) -> vec3<f32> {
    let m = mat3x3<f32>(
        vec3<f32>(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
        vec3<f32>(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
        vec3<f32>(-0.0990297440797205, -0.0989611768448433, 1.15107367264116),
    );
    return pow(max(m * v, vec3<f32>(0.0)), vec3<f32>(2.2));
}

fn srgb(c: vec3<f32>) -> vec3<f32> {
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(hi, lo, c <= vec3<f32>(0.0031308));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = textureDimensions(hdr);
    if gid.x >= size.x || gid.y >= size.y {
        return;
    }
    let c = textureLoad(hdr, vec2<i32>(gid.xy), 0).rgb * tone.exposure;
    var v = agx(c);
    // Look: a touch of contrast and saturation around mid grey.
    let luma = dot(v, vec3<f32>(0.2126, 0.7152, 0.0722));
    v = mix(vec3<f32>(luma), v, tone.saturation);
    v = clamp((v - 0.5) * tone.contrast + 0.5, vec3<f32>(0.0), vec3<f32>(1.0));
    let out = srgb(clamp(agx_eotf(v), vec3<f32>(0.0), vec3<f32>(1.0)));
    textureStore(ldr, vec2<i32>(gid.xy), vec4<f32>(out, 1.0));
}
