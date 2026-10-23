// Visibility buffer raster: every visible cluster is one instance of a
// 128-triangle draw; vertices are pulled from storage buffers. The colour
// target stores which triangle covers each pixel; shading happens later,
// once per pixel.

struct View {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    cam: vec4<f32>,
    planes: array<vec4<f32>, 6>,
    params: vec4<f32>,
    size: vec4<f32>,
    extra: vec4<f32>,
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

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) id: u32,
    @location(1) @interpolate(flat) material: u32,
    @location(2) uv: vec2<f32>,
};

@vertex
fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
    var o: VOut;
    let vis = visible[ii];
    let cl = clusters[vis.y];
    let tri = vi / 3u;
    if tri >= cl.tri_count {
        o.pos = vec4<f32>(2.0, 2.0, 2.0, 1.0); // degenerate, outside the clip volume
        return o;
    }
    let inst = instances[vis.x];
    let packed = tris[cl.first_tri + tri];
    let local = (packed >> (8u * (vi % 3u))) & 0xffu;
    let v = cluster_verts[cl.first_vert + local] * 8u;
    let p = vec4<f32>(vertices[v], vertices[v + 1u], vertices[v + 2u], 1.0);
    let w = vec3<f32>(dot(inst.r0, p), dot(inst.r1, p), dot(inst.r2, p));
    o.pos = view.view_proj * vec4<f32>(w, 1.0);
    o.id = (ii << 7u) | tri;
    o.material = cl.material;
    o.uv = vec2<f32>(vertices[v + 6u], vertices[v + 7u]);
    return o;
}

fn alpha_cut(in: VOut) -> bool {
    let dx = dpdx(in.uv);
    let dy = dpdy(in.uv);
    let m = materials[in.material];
    if (m.flags & 1u) != 0u && m.layer >= 0 {
        let a = textureSampleGrad(albedo, samp, in.uv, m.layer, dx, dy).a;
        return a < view.extra.x; // per frame under TAA: soft coverage over time
    }
    return false;
}

@fragment
fn fs(in: VOut) -> @location(0) u32 {
    if alpha_cut(in) {
        discard;
    }
    return in.id;
}

@fragment
fn fs_depth(in: VOut) {
    if alpha_cut(in) {
        discard;
    }
}
