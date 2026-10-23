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
    pad: f32,
};

@group(0) @binding(0) var<storage, read> vertices: array<f32>;
@group(0) @binding(1) var<storage, read> cluster_verts: array<u32>;
@group(0) @binding(2) var<storage, read> tris: array<u32>;
@group(0) @binding(3) var<storage, read> clusters: array<Cluster>;
@group(0) @binding(4) var<storage, read> instances: array<Instance>;
@group(0) @binding(5) var<storage, read> materials: array<Material>;
@group(0) @binding(6) var albedo: texture_2d_array<f32>;
@group(0) @binding(7) var samp: sampler;

@group(1) @binding(0) var<uniform> view: View;
@group(1) @binding(1) var<storage, read> visible: array<vec2<u32>>;
@group(1) @binding(2) var<uniform> light: Light;
@group(1) @binding(3) var vis_tex: texture_2d<u32>;
@group(1) @binding(4) var depth_tex: texture_depth_2d;
@group(1) @binding(5) var shadow_tex: texture_depth_2d;
@group(1) @binding(6) var shadow_samp: sampler_comparison;
@group(1) @binding(7) var sky_tex: texture_2d<f32>;
@group(1) @binding(8) var out_hdr: texture_storage_2d<rgba16float, write>;

const PI: f32 = 3.14159265;

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
    // Texture LOD from distance and view angle (no derivatives in compute).
    let footprint = dist * view.size.w * 2.0 / max(abs(dot(n, dir)), 0.25);
    var base = m.tint;
    if (m.flags & 2u) != 0u {
        // Terrain: forest floor, needles, a grassy verge near the road, rock
        // where it is steep. uv.x is metres from the road edge.
        let wuv = p.xz / m.scale;
        let lod = log2(max(footprint / m.scale * 1024.0, 1.0));
        let ground = tex(m.layer, wuv, lod).rgb;
        let needles = tex(m.layer + 1, wuv * 0.7, lod).rgb;
        let verge = tex(m.layer + 2, wuv * 1.3, lod).rgb;
        let rock = tex(m.layer + 3, p.xy / (m.scale * 1.5), lod).rgb;
        let patch_ = smoothstep(0.35, 0.65, vnoise(p.xz * 0.08));
        var c = mix(ground, needles, patch_);
        c = mix(verge, c, smoothstep(1.0, 9.0, uv.x));
        c = mix(c, rock, smoothstep(0.78, 0.6, n.y));
        base = c * m.tint;
    } else if (m.flags & 4u) != 0u {
        // Road: gravel along the ribbon, uv = (across -1..1, metres along).
        let ruv = vec2<f32>(uv.x * 3.4, uv.y) / m.scale;
        let lod = log2(max(footprint / m.scale * 1024.0, 1.0));
        let gravel = tex(m.layer, ruv, lod).rgb;
        let loose = tex(m.layer + 1, ruv * 0.8, lod).rgb;
        let edge = smoothstep(0.85, 1.15, abs(uv.x));
        base = mix(gravel, loose, edge) * m.tint;
        // Tracks: packed darker in the wheel lines.
        let track = exp(-pow((abs(uv.x) - 0.25) / 0.09, 2.0));
        base *= 1.0 - 0.25 * track;
    } else if m.layer >= 0 {
        let lod = log2(max(footprint * 256.0, 1.0));
        base = tex(m.layer, uv, lod).rgb * m.tint;
    }
    let l = light.sun_dir.xyz;
    let ndl = dot(n, l);
    var sun = max(ndl, 0.0);
    // Foliage cards let light through.
    if (m.flags & 8u) != 0u {
        sun = max(ndl, 0.0) * 0.8 + max(-ndl, 0.0) * 0.35;
    }
    var shadow = 1.0;
    if sun > 0.0 {
        shadow = mix(1.0, shadow_at(p, geo_n * sign(dot(geo_n, l) + 1e-4)), light.sun_color.w);
    }
    let diffuse = base / PI;
    // Sky light, darkened a little where the surface faces down into shade.
    let ambient = sky_irradiance(n) * (0.55 + 0.45 * shadow);
    var rad = diffuse * (light.sun_color.rgb * light.sun_dir.w * sun * shadow + ambient);
    // Distance fog in the sky's colour at the horizon.
    let f_lin = clamp((dist - light.fog_color.w) / max(light.fog.x - light.fog_color.w, 1.0), 0.0, 1.0);
    let f_exp = 1.0 - exp(-light.fog.y * dist);
    let f = max(f_lin, f_exp);
    let fog_rad = light.fog_color.rgb; // radiance (cd/m2) of the horizon
    rad = mix(rad, fog_rad, f);
    textureStore(out_hdr, px, vec4<f32>(rad, 1.0));
}
