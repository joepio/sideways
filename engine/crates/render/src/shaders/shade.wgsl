// Deferred shading from the visibility buffer: per pixel, find the
// triangle, intersect the view ray with it for exact barycentrics, and
// light the surface in physical units (lux, cd/m2). Output is linear HDR.

struct View {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    cam: vec4<f32>,
    planes: array<vec4<f32>, 6>,
    params: vec4<f32>,
    size: vec4<f32>,
    extra: vec4<f32>,
};

struct Light {
    sun_dir: vec4<f32>,      // towards the sun; w: illuminance in lux
    sun_color: vec4<f32>,    // linear colour; w: shadow strength
    shadow_view_proj: mat4x4<f32>,
    sky: vec4<f32>,          // x: sky luminance scale, y: sky rotation (rad), z: exposure, w: shadow texel (m)
    fog_color: vec4<f32>,    // horizon radiance; w: fog start (m)
    fog: vec4<f32>,          // x: fog end (m), y: exponential density, z: height falloff, w: wetness
    sh: array<vec4<f32>, 9>, // sky irradiance, SH9, already in lux
};

struct Cluster {
    cull: vec4<f32>,
    parent: vec4<f32>,
    own: vec4<f32>,
    parent_error: f32,
    own_error: f32,
    first_tri: u32,
    tri_count: u32,
    first_vert: u32,
    material: u32,
    depth: u32,
    pad: u32,
};

struct Instance {
    r0: vec4<f32>,
    r1: vec4<f32>,
    r2: vec4<f32>,
    sphere: vec4<f32>,
    first_cluster: u32,
    cluster_count: u32,
    scale: f32,
    pad: u32,
};

struct Material {
    tint: vec3<f32>,
    layer: i32,
    roughness: f32,
    flags: u32,
    scale: f32,
    metal: f32,
};

@group(0) @binding(0) var<storage, read> vertices: array<f32>;
@group(0) @binding(1) var<storage, read> cluster_verts: array<u32>;
@group(0) @binding(2) var<storage, read> tris: array<u32>;
@group(0) @binding(3) var<storage, read> clusters: array<Cluster>;
@group(0) @binding(4) var<storage, read> instances: array<Instance>;
@group(0) @binding(5) var<storage, read> materials: array<Material>;
@group(0) @binding(6) var albedo: texture_2d_array<f32>;
@group(0) @binding(7) var samp: sampler;
@group(0) @binding(8) var<storage, read> aux: array<u32>;
@group(0) @binding(9) var normal_tex: texture_2d_array<f32>;

@group(1) @binding(0) var<uniform> view: View;
@group(1) @binding(1) var<storage, read> visible: array<vec2<u32>>;
@group(1) @binding(2) var<uniform> light: Light;
@group(1) @binding(3) var vis_tex: texture_2d<u32>;
@group(1) @binding(4) var depth_tex: texture_depth_2d;
@group(1) @binding(5) var shadow_tex: texture_depth_2d;
@group(1) @binding(6) var shadow_samp: sampler_comparison;
@group(1) @binding(7) var sky_tex: texture_2d<f32>;
@group(1) @binding(8) var out_hdr: texture_storage_2d<rgba16float, write>;
@group(1) @binding(9) var<storage, read> density: array<u32>;
@group(1) @binding(10) var heightfield: texture_2d<f32>;
@group(1) @binding(11) var<uniform> gi: Gi;

struct Gi {
    vol_origin: vec4<f32>,
    vol_dims: vec4<u32>,
    hf: vec4<f32>,
    hf_dims: vec4<u32>,
    bounce: vec4<f32>,
};

// Foliage density 0..1 at p (nearest voxel), 0 outside the volume.
fn foliage(p: vec3<f32>) -> f32 {
    let q = vec3<i32>(floor((p - gi.vol_origin.xyz) / gi.vol_origin.w));
    let d = vec3<i32>(gi.vol_dims.xyz);
    if any(q < vec3<i32>(0)) || any(q >= d) {
        return 0.0;
    }
    return f32(density[(q.z * d.y + q.y) * d.x + q.x]) / 255.0;
}

// Terrain height at (x, z), bilinear; -1e9 outside the heightfield.
fn ground_at(xz: vec2<f32>) -> f32 {
    let g = (xz - gi.hf.xy) / gi.hf.z;
    let d = vec2<i32>(gi.hf_dims.xy);
    let i = vec2<i32>(floor(g));
    if any(i < vec2<i32>(0)) || any(i >= d - 1) {
        return -1e9;
    }
    let f = g - vec2<f32>(i);
    let a = textureLoad(heightfield, i, 0).r;
    let b = textureLoad(heightfield, i + vec2<i32>(1, 0), 0).r;
    let c = textureLoad(heightfield, i + vec2<i32>(0, 1), 0).r;
    let e = textureLoad(heightfield, i + vec2<i32>(1, 1), 0).r;
    return mix(mix(a, b, f.x), mix(c, e, f.x), f.y);
}

// How much light gets from direction `dir` to p, through the canopy and
// past the terrain: steps grow with distance, like a cone widening.
fn transmittance(p: vec3<f32>, dir: vec3<f32>, max_t: f32) -> f32 {
    var t = 0.5;
    var tr = 1.0;
    for (var k = 0; k < 12; k++) {
        let q = p + dir * t;
        if q.y < ground_at(q.xz) - 0.3 {
            return 0.0;
        }
        let step = max(t * 0.45, 0.6);
        tr *= exp(-foliage(q) * 0.9 * step);
        t += step;
        if t > max_t || tr < 0.02 {
            break;
        }
    }
    return tr;
}

// Fraction of the sky a surface sees: five cones around its normal.
fn sky_visibility(p: vec3<f32>, n: vec3<f32>) -> f32 {
    if gi.vol_dims.w == 0u {
        return 1.0;
    }
    let t1 = normalize(select(cross(n, vec3<f32>(0.0, 0.0, 1.0)), cross(n, vec3<f32>(1.0, 0.0, 0.0)), abs(n.x) < 0.9));
    let t2 = cross(n, t1);
    let o = p + n * 0.15;
    var v = transmittance(o, n, 60.0) * 2.0;
    v += transmittance(o, normalize(n + t1 * 1.2), 40.0);
    v += transmittance(o, normalize(n - t1 * 1.2), 40.0);
    v += transmittance(o, normalize(n + t2 * 1.2), 40.0);
    v += transmittance(o, normalize(n - t2 * 1.2), 40.0);
    return v / 6.0;
}

const PI: f32 = 3.14159265;

// GGX microfacet specular for a light from l (Karis 2013): D * Vis * F * n.l.
fn ggx(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, rough: f32, f0: vec3<f32>) -> vec3<f32> {
    let h = normalize(v + l);
    let ndl = max(dot(n, l), 0.0);
    let ndv = max(dot(n, v), 1e-4);
    let ndh = max(dot(n, h), 0.0);
    let a = max(rough * rough, 2e-3);
    let a2 = a * a;
    let d = a2 / (PI * pow(ndh * ndh * (a2 - 1.0) + 1.0, 2.0));
    let vis = 0.5 / (ndl * sqrt(ndv * ndv * (1.0 - a2) + a2) + ndv * sqrt(ndl * ndl * (1.0 - a2) + a2) + 1e-5);
    let f = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
    return d * vis * f * ndl;
}

// Split-sum environment BRDF, analytic fit (Karis, mobile).
fn env_brdf(f0: vec3<f32>, rough: f32, ndv: f32) -> vec3<f32> {
    let c0 = vec4<f32>(-1.0, -0.0275, -0.572, 0.022);
    let c1 = vec4<f32>(1.0, 0.0425, 1.04, -0.04);
    let r = rough * c0 + c1;
    let a004 = min(r.x * r.x, exp2(-9.28 * ndv)) * r.x + r.y;
    let ab = vec2<f32>(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// Radiance arriving along r: the sky above the horizon (blurred into its
// irradiance as the surface gets rougher), lit ground below it.
fn environment(r: vec3<f32>, rough: f32) -> vec3<f32> {
    let sky = mix(sky_radiance(r), sky_irradiance(r) / PI, smoothstep(0.05, 0.55, rough));
    let ground = gi.bounce.rgb * 1.5 / PI;
    return mix(ground, sky, smoothstep(-0.08, 0.04, r.y));
}

fn vtx(i: u32) -> u32 {
    return i * 8u;
}

fn pos_of(v: u32) -> vec3<f32> {
    return vec3<f32>(vertices[v], vertices[v + 1u], vertices[v + 2u]);
}

fn xform(inst: Instance, p: vec3<f32>) -> vec3<f32> {
    let q = vec4<f32>(p, 1.0);
    return vec3<f32>(dot(inst.r0, q), dot(inst.r1, q), dot(inst.r2, q));
}

fn xform_dir(inst: Instance, d: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(inst.r0.xyz, d), dot(inst.r1.xyz, d), dot(inst.r2.xyz, d));
}

fn sky_dir_uv(d: vec3<f32>) -> vec2<f32> {
    let a = light.sky.y;
    let x = d.x * cos(a) - d.z * sin(a);
    let z = d.x * sin(a) + d.z * cos(a);
    let u = atan2(x, -z) / (2.0 * PI) + 0.5;
    let v = acos(clamp(d.y, -1.0, 1.0)) / PI;
    return vec2<f32>(u, v);
}

fn sky_radiance(d: vec3<f32>) -> vec3<f32> {
    let dims = vec2<f32>(textureDimensions(sky_tex));
    let uv = sky_dir_uv(d);
    let px = vec2<i32>(clamp(uv * dims, vec2<f32>(0.0), dims - 1.0));
    return textureLoad(sky_tex, px, 0).rgb * light.sky.x;
}

// Irradiance (lux) from the sky for a surface facing n.
fn sky_irradiance(n: vec3<f32>) -> vec3<f32> {
    let c1 = 0.429043;
    let c2 = 0.511664;
    let c3 = 0.743125;
    let c4 = 0.886227;
    let c5 = 0.247708;
    let s = light.sh;
    let e = c1 * s[8].rgb * (n.x * n.x - n.y * n.y) + c3 * s[6].rgb * n.z * n.z + c4 * s[0].rgb - c5 * s[6].rgb
        + 2.0 * c1 * (s[4].rgb * n.x * n.y + s[7].rgb * n.x * n.z + s[5].rgb * n.y * n.z)
        + 2.0 * c2 * (s[3].rgb * n.x + s[1].rgb * n.y + s[2].rgb * n.z);
    return max(e, vec3<f32>(0.0));
}

fn shadow_at(p: vec3<f32>, n: vec3<f32>) -> f32 {
    let biased = p + n * light.sky.w * 1.5 + light.sun_dir.xyz * light.sky.w;
    let c = light.shadow_view_proj * vec4<f32>(biased, 1.0);
    let uv = vec2<f32>(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) || c.z > 1.0 {
        return 1.0;
    }
    let texel = 1.0 / vec2<f32>(textureDimensions(shadow_tex));
    var lit = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            lit += textureSampleCompareLevel(shadow_tex, shadow_samp, uv + vec2<f32>(f32(x), f32(y)) * texel, c.z);
        }
    }
    return lit / 9.0;
}

fn tex(layer: i32, uv: vec2<f32>, lod: f32) -> vec4<f32> {
    return textureSampleLevel(albedo, samp, uv, layer, lod);
}

// The surface's footprint across one pixel, from ray differentials: the
// rays through the next pixel right and down, hit on the triangle's plane.
struct Footprint {
    dx: vec3<f32>,
    dy: vec3<f32>,
};

var<private> fp: Footprint;

// Sample with the true texture-space gradients (anisotropic filtering):
// uv = (world position projected on `ax`, `ay`) / scale.
fn tex_w(layer: i32, uv: vec2<f32>, gx: vec2<f32>, gy: vec2<f32>) -> vec4<f32> {
    return textureSampleGrad(albedo, samp, uv, layer, gx, gy);
}

fn tex_xz(layer: i32, uv: vec2<f32>, scale: f32) -> vec4<f32> {
    return tex_w(layer, uv, fp.dx.xz / scale, fp.dy.xz / scale);
}

// Tangent-space normal (xy in -1..1) of layer l, sampled like the albedo.
fn nrm(l: i32, uv: vec2<f32>, gx: vec2<f32>, gy: vec2<f32>) -> vec2<f32> {
    return textureSampleGrad(normal_tex, samp, uv, l, gx, gy).xy * 2.0 - 1.0;
}

fn nrm_xz(l: i32, uv: vec2<f32>, scale: f32) -> vec2<f32> {
    return nrm(l, uv, fp.dx.xz / scale, fp.dy.xz / scale);
}

fn safe_normalize(v: vec3<f32>) -> vec3<f32> {
    return v / max(length(v), 1e-6);
}

// Bend n by a tangent-space normal xy. t = dP/du and b = -dP/dv: OpenGL
// normal maps (Godot's) point green towards the image's top row.
fn perturb(n: vec3<f32>, xy: vec2<f32>, t: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let tt = safe_normalize(t - n * dot(n, t));
    let bb = safe_normalize(b - n * dot(n, b));
    let z = sqrt(max(1.0 - dot(xy, xy), 0.0));
    return safe_normalize(tt * xy.x + bb * xy.y + n * z);
}

// The normal map in the planar xz mapping: u along +x, v along +z.
fn perturb_xz(n: vec3<f32>, xy: vec2<f32>) -> vec3<f32> {
    return perturb(n, xy, vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, -1.0));
}

// Triplanar normal map, matching `triplanar` below. A sample taken at
// rot * uv turns back with rot (the v flip makes the inverse rot again).
fn triplanar_n(l: i32, p: vec3<f32>, n: vec3<f32>, tw: vec3<f32>, scale: f32, rot: mat2x2<f32>, shift: f32) -> vec3<f32> {
    let k = 1.0 / scale;
    let x = rot * nrm(l, rot * p.zy * k + shift, rot * fp.dx.zy * k, rot * fp.dy.zy * k);
    let y = rot * nrm(l, rot * p.xz * k + shift, rot * fp.dx.xz * k, rot * fp.dy.xz * k);
    let z = rot * nrm(l, rot * p.xy * k + shift, rot * fp.dx.xy * k, rot * fp.dy.xy * k);
    let nx = perturb(n, x, vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, -1.0, 0.0));
    let ny = perturb(n, y, vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, -1.0));
    let nz = perturb(n, z, vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, -1.0, 0.0));
    return safe_normalize(nx * tw.x + ny * tw.y + nz * tw.z);
}

// World directions of the mesh uv on a triangle: (dP/du, -dP/dv).
fn uv_frame(e1: vec3<f32>, e2: vec3<f32>, vi: array<u32, 3>) -> array<vec3<f32>, 2> {
    let uv0 = vec2<f32>(vertices[vi[0] + 6u], vertices[vi[0] + 7u]);
    let d1 = vec2<f32>(vertices[vi[1] + 6u], vertices[vi[1] + 7u]) - uv0;
    let d2 = vec2<f32>(vertices[vi[2] + 6u], vertices[vi[2] + 7u]) - uv0;
    let det = d1.x * d2.y - d2.x * d1.y;
    let r = select(1.0 / det, 0.0, abs(det) < 1e-12);
    let dpdu = (e1 * d2.y - e2 * d1.y) * r;
    let dpdv = (e2 * d1.x - e1 * d2.x) * r;
    return array<vec3<f32>, 2>(dpdu, -dpdv);
}

// Triplanar: three planar projections of `scale` metres, blended by tw.
fn triplanar(l: i32, p: vec3<f32>, tw: vec3<f32>, scale: f32, rot: mat2x2<f32>, shift: f32) -> vec3<f32> {
    let k = 1.0 / scale;
    let x = tex_w(l, rot * p.zy * k + shift, rot * fp.dx.zy * k, rot * fp.dy.zy * k).rgb;
    let y = tex_w(l, rot * p.xz * k + shift, rot * fp.dx.xz * k, rot * fp.dy.xz * k).rgb;
    let z = tex_w(l, rot * p.xy * k + shift, rot * fp.dx.xy * k, rot * fp.dy.xy * k).rgb;
    return x * tw.x + y * tw.y + z * tw.z;
}

// The change in the mesh uv for a step d on the triangle (p0, e1, e2).
fn uv_at(d: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, vi: array<u32, 3>) -> vec2<f32> {
    let d00 = dot(e1, e1);
    let d01 = dot(e1, e2);
    let d11 = dot(e2, e2);
    let d20 = dot(d, e1);
    let d21 = dot(d, e2);
    let den = d00 * d11 - d01 * d01;
    let inv = select(1.0 / den, 0.0, abs(den) < 1e-20);
    let b1 = (d11 * d20 - d01 * d21) * inv;
    let b2 = (d00 * d21 - d01 * d20) * inv;
    let uv0 = vec2<f32>(vertices[vi[0] + 6u], vertices[vi[0] + 7u]);
    let uv1 = vec2<f32>(vertices[vi[1] + 6u], vertices[vi[1] + 7u]);
    let uv2 = vec2<f32>(vertices[vi[2] + 6u], vertices[vi[2] + 7u]);
    return (uv1 - uv0) * b1 + (uv2 - uv0) * b2;
}

const TURN: mat2x2<f32> = mat2x2<f32>(vec2<f32>(0.8, 0.6), vec2<f32>(-0.6, 0.8));

fn fbm(p: vec2<f32>) -> f32 {
    return vnoise(p) * 0.55 + vnoise(p * 2.1) * 0.3 + vnoise(p * 4.3) * 0.15;
}

// layer2's normal map, blended the same way.
fn layer2n(l: i32, uv: vec2<f32>, scale: f32, far: f32, mixer: f32) -> vec2<f32> {
    let a = nrm_xz(l, uv / scale, scale);
    let k = scale * 4.3;
    let b = TURN * nrm(l, TURN * uv / k, TURN * fp.dx.xz / k, TURN * fp.dy.xz / k);
    return mix(a, b, clamp(mixer + far * 0.4, 0.0, 1.0));
}

// Two scales of one texture, blended by distance and noise: no visible tiling.
fn layer2(l: i32, uv: vec2<f32>, scale: f32, far: f32, mixer: f32) -> vec3<f32> {
    let a = tex_xz(l, uv / scale, scale).rgb;
    let k = scale * 4.3;
    let b = tex_w(l, TURN * uv / k, TURN * fp.dx.xz / k, TURN * fp.dy.xz / k).rgb;
    return mix(a, b, clamp(mixer + far * 0.4, 0.0, 1.0));
}

fn hash2(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + vec2<f32>(1.0, 0.0)), u.x), mix(hash2(i + vec2<f32>(0.0, 1.0)), hash2(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

@compute @workgroup_size(8, 8)
fn shade(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = vec2<u32>(view.size.xy);
    if gid.x >= size.x || gid.y >= size.y {
        return;
    }
    let px = vec2<i32>(gid.xy);
    let ndc = vec2<f32>((f32(gid.x) + 0.5) / view.size.x * 2.0 - 1.0, 1.0 - (f32(gid.y) + 0.5) / view.size.y * 2.0);
    let far = view.inv_view_proj * vec4<f32>(ndc, 1e-4, 1.0);
    let dir = normalize(far.xyz / far.w - view.cam.xyz);
    let depth = textureLoad(depth_tex, px, 0);
    if depth <= 0.0 {
        textureStore(out_hdr, px, vec4<f32>(sky_radiance(dir), 1.0));
        return;
    }
    let id = textureLoad(vis_tex, px, 0).r;
    let vis = visible[id >> 7u];
    let tri = id & 127u;
    let cl = clusters[vis.y];
    let inst = instances[vis.x];
    let packed = tris[cl.first_tri + tri];
    var vi: array<u32, 3>;
    for (var k = 0u; k < 3u; k++) {
        vi[k] = vtx(cluster_verts[cl.first_vert + ((packed >> (8u * k)) & 0xffu)]);
    }
    let p0 = xform(inst, pos_of(vi[0]));
    let p1 = xform(inst, pos_of(vi[1]));
    let p2 = xform(inst, pos_of(vi[2]));
    // Ray-triangle intersection for perspective-correct barycentrics.
    let e1 = p1 - p0;
    let e2 = p2 - p0;
    let pv = cross(dir, e2);
    let det = dot(e1, pv);
    let tv = view.cam.xyz - p0;
    let inv = select(1.0 / det, 0.0, abs(det) < 1e-12);
    let b1 = clamp(dot(tv, pv) * inv, 0.0, 1.0);
    let qv = cross(tv, e1);
    let b2 = clamp(dot(dir, qv) * inv, 0.0, 1.0 - b1);
    let b0 = 1.0 - b1 - b2;
    let p = p0 * b0 + p1 * b1 + p2 * b2;
    var n = vec3<f32>(0.0);
    var uv = vec2<f32>(0.0);
    let w = array<f32, 3>(b0, b1, b2);
    for (var k = 0u; k < 3u; k++) {
        let v = vi[k];
        n += vec3<f32>(vertices[v + 3u], vertices[v + 4u], vertices[v + 5u]) * w[k];
        uv += vec2<f32>(vertices[v + 6u], vertices[v + 7u]) * w[k];
    }
    n = normalize(xform_dir(inst, n));
    let geo_n = normalize(cross(e1, e2));
    let m = materials[cl.material];
    // Two-sided cards and backfaces face the viewer.
    if dot(n, dir) > 0.0 && (m.flags & 8u) != 0u {
        n = -n;
    }
    let dist = distance(p, view.cam.xyz);
    // Ray differentials: where the neighbouring pixels' rays meet this
    // triangle's plane. Gives exact, anisotropic texture footprints.
    let px_x = view.inv_view_proj * vec4<f32>(ndc + vec2<f32>(2.0 * view.size.z, 0.0), 1e-4, 1.0);
    let px_y = view.inv_view_proj * vec4<f32>(ndc - vec2<f32>(0.0, 2.0 * view.size.w), 1e-4, 1.0);
    let dir_x = normalize(px_x.xyz / px_x.w - view.cam.xyz);
    let dir_y = normalize(px_y.xyz / px_y.w - view.cam.xyz);
    let plane_d = dot(p - view.cam.xyz, geo_n);
    let hit_x = view.cam.xyz + dir_x * (plane_d / select(dot(dir_x, geo_n), 1e-6, abs(dot(dir_x, geo_n)) < 1e-6));
    let hit_y = view.cam.xyz + dir_y * (plane_d / select(dot(dir_y, geo_n), 1e-6, abs(dot(dir_y, geo_n)) < 1e-6));
    let reach = dist * 0.05 + 0.05; // grazing hits run off towards infinity
    fp.dx = clamp(hit_x - p, vec3<f32>(-reach), vec3<f32>(reach));
    fp.dy = clamp(hit_y - p, vec3<f32>(-reach), vec3<f32>(reach));
    let duv_x = uv_at(fp.dx, e1, e2, vi) ;
    let duv_y = uv_at(fp.dy, e1, e2, vi);
    var base = m.tint;
    var nn = n; // the normal after normal maps
    if (m.flags & 2u) != 0u {
        // Terrain (src/shaders/terrain.gdshader): moss, needles, a grassy
        // verge, bare ground beside the road and rock where it is steep.
        // uv.x is metres from the road edge. Layers m.layer .. m.layer+4.
        let wuv = p.xz;
        let far = smoothstep(30.0, 140.0, dist);
        let lmix = smoothstep(0.2, 0.8, fbm(wuv / 8.0 + 21.0)) * 0.6;
        let moss = layer2(m.layer, wuv, 3.2, far, lmix) * vec3<f32>(0.78, 0.86, 0.7);
        let needles = layer2(m.layer + 1, wuv, 2.8, far, lmix) * vec3<f32>(0.72, 0.66, 0.6);
        let verge = layer2(m.layer + 2, wuv, 2.6, far, lmix) * vec3<f32>(0.68, 0.94, 0.70);
        let ground = layer2(m.layer + 3, wuv, 3.0, far, lmix) * vec3<f32>(0.85, 0.8, 0.75);
        let road_d = clamp(uv.x / 14.0, 0.0, 1.0);
        let up = n.y;
        let m_needles = smoothstep(0.48, 0.62, fbm(wuv / 11.0 + 7.0));
        // Grass on the verge, thinning into the wood, patchy in clearings.
        let m_verge = clamp((1.0 - smoothstep(6.0, 24.0, uv.x)) * 0.85 + smoothstep(0.55, 0.8, fbm(wuv / 23.0 + 3.0)) * 0.5, 0.0, 1.0);
        var m_bare = 1.0 - smoothstep(0.03, 0.12, road_d + (fbm(wuv / 2.5) - 0.5) * 0.12);
        m_bare = max(m_bare, smoothstep(0.82, 0.62, up) * 0.8);
        var c = mix(moss, needles, m_needles);
        c = mix(c, verge, m_verge);
        c = mix(c, ground, m_bare);
        var nt = mix(layer2n(m.layer, wuv, 3.2, far, lmix), layer2n(m.layer + 1, wuv, 2.8, far, lmix), m_needles);
        nt = mix(nt, layer2n(m.layer + 2, wuv, 2.6, far, lmix), m_verge);
        nt = mix(nt, layer2n(m.layer + 3, wuv, 3.0, far, lmix), m_bare);
        nn = perturb_xz(n, nt);
        c *= 0.78 + 0.34 * fbm(wuv / 31.0);
        let m_rock = smoothstep(0.72, 0.5, up + (fbm(wuv / 3.0) - 0.5) * 0.15);
        if m_rock > 0.0 {
            var tw = pow(abs(n), vec3<f32>(4.0));
            tw /= tw.x + tw.y + tw.z;
            let rp = p.xz + p.yy * 0.7;
            let rmix = smoothstep(0.25, 0.75, fbm(rp / 6.0 + 3.0));
            let rl = m.layer + 4;
            let a = triplanar(rl, p, tw, 3.7, mat2x2<f32>(1.0, 0.0, 0.0, 1.0), 0.0);
            let b = triplanar(rl, p, tw, 11.3, TURN, 0.37);
            var rock = mix(a, b, rmix) * vec3<f32>(0.62, 0.63, 0.62);
            let strata = 0.88 + 0.12 * sin(p.y * 2.1 + fbm(rp / 5.0) * 5.0);
            let stain = fbm(rp / 17.0 + 11.0);
            rock *= strata * (0.75 + 0.45 * stain);
            rock = mix(rock, rock * vec3<f32>(0.85, 0.95, 0.7), smoothstep(0.55, 0.75, fbm(rp / 3.0 + 5.0)) * 0.6);
            c = mix(c, rock, m_rock);
            let rn = safe_normalize(mix(triplanar_n(rl, p, n, tw, 3.7, mat2x2<f32>(1.0, 0.0, 0.0, 1.0), 0.0), triplanar_n(rl, p, n, tw, 11.3, TURN, 0.37), rmix));
            nn = safe_normalize(mix(nn, rn, m_rock));
        }
        base = c * mix(1.0, 0.7, light.fog.w) * m.tint;
    } else if (m.flags & 4u) != 0u {
        // Road (src/shaders/road.gdshader): uv = (across -1..1, metres
        // along); aux holds the surface per 2 m row (3 earth, 5 asphalt, 6 mud).
        var wuv = p.xz;
        let rows = arrayLength(&aux);
        let row = u32(clamp(floor(uv.y / 2.0), 0.0, f32(max(rows, 1u) - 1u)));
        let surf = select(0u, aux[row], rows > 0u);
        let a = abs(uv.x);
        let firm = 1.0 - smoothstep(0.85, 1.05, a);
        let earth = select(0.0, 1.0, surf == 3u) * firm;
        let muddy = select(0.0, 1.0, surf == 6u) * firm;
        let asphalt = select(0.0, 1.0, surf == 5u) * firm;
        let road_wet = mix(light.fog.w, max(light.fog.w, 0.55), muddy);
        let rut = exp(-pow((a - 0.25) / 0.085, 2.0));
        let ridge = max(exp(-pow(uv.x / 0.07, 2.0)), exp(-pow((a - 0.8) / 0.08, 2.0)));
        let edge = smoothstep(0.62, 0.95, a + (vnoise(wuv / 2.0) - 0.5) * 0.25);
        let shoulder = smoothstep(1.0, 1.2, a);
        let aggregate = mix(2.6, 0.65, asphalt);
        var gr = tex_xz(m.layer, wuv / aggregate, aggregate).rgb;
        let g2 = tex_xz(m.layer, wuv / 11.0, 11.0).rgb;
        gr = mix(gr, g2, 0.3);
        let far_d = smoothstep(10.0, 45.0, dist);
        gr = mix(gr, tex(m.layer, wuv / 2.6, 9.0).rgb, far_d * 0.7);
        let lo = tex_xz(m.layer + 1, wuv / 2.2, 2.2).rgb;
        var c = gr * vec3<f32>(0.66, 0.62, 0.56);
        c = mix(c, c * 0.72, rut * 0.75);
        c = mix(c, mix(gr * vec3<f32>(0.7, 0.66, 0.6), lo * 0.8, 0.5), edge);
        c = mix(c, lo * 0.7, shoulder);
        c = mix(c, mix(gr, lo, 0.3) * vec3<f32>(0.78, 0.74, 0.68), ridge * 0.6);
        c *= 0.9 + 0.2 * vnoise(wuv / 7.0);
        let green = smoothstep(0.45, 0.7, vnoise(wuv / 6.0 + 13.0)) * smoothstep(0.3, 0.8, exp(-pow(uv.x / 0.07, 2.0))) * smoothstep(0.35, 0.65, vnoise(wuv * 2.3));
        c = mix(c, vec3<f32>(0.2, 0.25, 0.11) * (0.8 + 0.4 * gr.g), green * 0.75);
        c *= 0.85 + 0.3 * smoothstep(0.3, 0.7, vnoise(wuv / 23.0 + 4.0));
        let smear = vnoise(vec2<f32>(uv.x * 70.0, uv.y * 0.6)) * 0.6 + vnoise(vec2<f32>(uv.x * 140.0, uv.y * 1.3)) * 0.4;
        let worn = clamp(rut * (0.65 + 0.35 * smear), 0.0, 1.0);
        let fines = tex(m.layer, wuv / 2.6, 6.0).rgb * vec3<f32>(0.66, 0.6, 0.52);
        var mud = mix(fines, lo * vec3<f32>(0.5, 0.44, 0.36), 0.35) * (0.82 + 0.3 * smear);
        mud *= mix(1.0, 0.7, road_wet);
        c = mix(c, mud, worn * 0.85);
        c *= mix(1.0, 0.62, road_wet);
        var earth_col = mix(g2 * vec3<f32>(0.55, 0.40, 0.26), lo * vec3<f32>(0.65, 0.50, 0.35), 0.4);
        earth_col *= (0.9 + 0.2 * smear) * mix(1.0, 0.65, road_wet);
        c = mix(c, earth_col, max(earth, muddy * 0.8));
        var asphalt_col = vec3<f32>(0.065, 0.068, 0.070) * (0.65 + 0.7 * dot(gr, vec3<f32>(0.333333)));
        asphalt_col *= mix(1.0, 0.88, worn) * mix(1.0, 0.7, light.fog.w);
        c = mix(c, asphalt_col, asphalt);
        base = c * m.tint;
        // Gravel relief, fading with distance; mud and asphalt are smoother.
        var rn = mix(nrm_xz(m.layer, wuv / aggregate, aggregate), nrm_xz(m.layer, wuv / 11.0, 11.0), 0.3);
        rn = mix(rn, nrm_xz(m.layer + 1, wuv / 2.2, 2.2), max(edge, shoulder));
        rn *= (1.0 - far_d * 0.6) * (1.0 - worn * 0.7) * (1.0 - asphalt * 0.6) * (1.0 - max(earth, muddy) * 0.4);
        nn = perturb_xz(n, rn);
    } else if (m.flags & 16u) != 0u && m.layer >= 0 {
        var tw = pow(abs(n), vec3<f32>(4.0));
        tw /= tw.x + tw.y + tw.z;
        base = triplanar(m.layer, p, tw, m.scale, mat2x2<f32>(1.0, 0.0, 0.0, 1.0), 0.0) * m.tint;
        nn = triplanar_n(m.layer, p, n, tw, m.scale, mat2x2<f32>(1.0, 0.0, 0.0, 1.0), 0.0);
    } else if m.layer >= 0 {
        base = tex_w(m.layer, uv, duv_x, duv_y).rgb * m.tint;
        var frame = uv_frame(e1, e2, vi);
        if dot(geo_n, n) < 0.0 {
            // The far side of a two-sided card: its relief is the mirror image.
            frame[0] = -frame[0];
            frame[1] = -frame[1];
        }
        nn = perturb(n, nrm(m.layer, uv, duv_x, duv_y), frame[0], frame[1]);
    }
    n = nn;
    let l = light.sun_dir.xyz;
    let ndl = dot(n, l);
    var sun = max(ndl, 0.0);
    var back = vec3<f32>(0.0);
    var ao = 1.0;
    let needles = (m.flags & 9u) == 9u;
    if needles {
        // foliage.gdshader: a little colour per tree, sunlight shining
        // through the needles from behind (BACKLIGHT), AO 0.85.
        base *= 0.82 + 0.3 * hash2(vec2<f32>(inst.r0.w, inst.r2.w));
        back = vec3<f32>(0.175, 0.21, 0.1) * max(-ndl, 0.0);
        ao = 0.85;
    }
    var shadow = 1.0;
    if sun > 0.0 || needles {
        var s_map = shadow_at(p, geo_n * sign(dot(geo_n, l) + 1e-4));
        // Beyond the shadow map the canopy volume shades the ground.
        let c = light.shadow_view_proj * vec4<f32>(p, 1.0);
        let edge = max(abs(c.x), abs(c.y));
        if edge > 0.85 && gi.vol_dims.w != 0u {
            let tr = transmittance(p + geo_n * 0.2, l, 50.0);
            s_map = mix(s_map, tr, smoothstep(0.85, 1.0, edge));
        }
        shadow = mix(1.0, s_map, light.sun_color.w);
    }
    // Base layer: Lambert plus GGX, metals tint their reflection.
    let v = -dir;
    let ndv = max(dot(n, v), 1e-4);
    let rough = clamp(m.roughness, 0.04, 1.0);
    var f0 = mix(vec3<f32>(0.04), base, m.metal);
    if needles {
        f0 = vec3<f32>(0.01); // foliage.gdshader: SPECULAR 0.125
    }
    let diffuse = base * (1.0 - m.metal) / PI;
    // Sky light where the sky is visible; light bounced off the sunlit
    // ground and foliage where it is not.
    let sky_vis = sky_visibility(p, n);
    let ambient = (sky_irradiance(n) * sky_vis + gi.bounce.rgb * (1.0 - sky_vis)) * ao;
    let sun_e = light.sun_color.rgb * light.sun_dir.w * shadow;
    let refl = reflect(dir, n);
    let env = environment(refl, rough) * sky_vis;
    var rad = diffuse * (sun_e * sun + ambient) + sun_e * back / PI;
    rad += sun_e * ggx(n, v, l, rough, f0) + env * env_brdf(f0, rough, ndv) * ao;
    if (m.flags & 32u) != 0u {
        // Clear coat: a thin glossy dielectric on top; what it reflects the
        // base does not get.
        let fc = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
        rad = rad * (1.0 - fc) + sun_e * ggx(n, v, l, 0.04, vec3<f32>(0.04)) + environment(refl, 0.04) * sky_vis * fc;
    }
    // Distance fog in the sky's colour at the horizon.
    let f_lin = clamp((dist - light.fog_color.w) / max(light.fog.x - light.fog_color.w, 1.0), 0.0, 1.0);
    let f_exp = 1.0 - exp(-light.fog.y * dist);
    let f = max(f_lin, f_exp);
    let fog_rad = light.fog_color.rgb; // radiance (cd/m2) of the horizon
    rad = mix(rad, fog_rad, f);
    // Debug view (light.sky.z): 1 shows sky visibility, 2 the albedo.
    if light.sky.z > 0.5 && light.sky.z < 1.5 {
        rad = vec3<f32>(sky_vis) * 6000.0;
    } else if light.sky.z > 1.5 {
        rad = base * 6000.0;
    }
    textureStore(out_hdr, px, vec4<f32>(rad, 1.0));
}
