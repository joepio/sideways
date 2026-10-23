// Cluster culling and LOD selection, one workgroup per instance.
// A cluster is drawn when its own error projects to at most the threshold
// and its group's simplified replacement would project above it.

struct View {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    cam: vec4<f32>,          // position; w: pixels per unit error at distance 1 (or per metre, ortho)
    planes: array<vec4<f32>, 6>,
    params: vec4<f32>,       // threshold px, znear, ortho, max visible
    size: vec4<f32>,
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

@group(0) @binding(3) var<storage, read> clusters: array<Cluster>;
@group(0) @binding(4) var<storage, read> instances: array<Instance>;

@group(1) @binding(0) var<uniform> view: View;
@group(1) @binding(1) var<storage, read_write> visible: array<vec2<u32>>;
@group(1) @binding(2) var<storage, read_write> counter: array<atomic<u32>, 4>;
@group(1) @binding(3) var<storage, read_write> args: array<u32, 4>;

fn in_frustum(c: vec3<f32>, r: f32) -> bool {
    for (var i = 0u; i < 6u; i++) {
        if dot(view.planes[i].xyz, c) + view.planes[i].w < -r {
            return false;
        }
    }
    return true;
}

fn to_world(inst: Instance, p: vec3<f32>) -> vec3<f32> {
    let q = vec4<f32>(p, 1.0);
    return vec3<f32>(dot(inst.r0, q), dot(inst.r1, q), dot(inst.r2, q));
}

// Screen-space size in pixels of `err` metres at the sphere's nearest point.
fn projected(err: f32, c: vec3<f32>, r: f32) -> f32 {
    if view.params.z > 0.5 {
        return err * view.cam.w;
    }
    let d = max(distance(c, view.cam.xyz) - r, view.params.y);
    return err / d * view.cam.w;
}

var<workgroup> keep: bool;

@compute @workgroup_size(64)
fn cull(@builtin(workgroup_id) wg: vec3<u32>, @builtin(local_invocation_index) li: u32) {
    let id = wg.x + wg.y * 65535u;
    let n = arrayLength(&instances);
    if id >= n {
        return;
    }
    let inst = instances[id];
    if li == 0u {
        keep = in_frustum(inst.sphere.xyz, inst.sphere.w);
    }
    workgroupBarrier();
    if !keep {
        return;
    }
    let thr = view.params.x;
    let max_visible = u32(view.params.w);
    for (var c = li; c < inst.cluster_count; c += 64u) {
        let ci = inst.first_cluster + c;
        let cl = clusters[ci];
        let s = inst.scale;
        let pc = to_world(inst, cl.parent.xyz);
        let parent_px = select(projected(cl.parent_error * s, pc, cl.parent.w * s), 1e30, cl.parent_error > 1e30);
        if parent_px <= thr {
            continue; // a coarser cluster covers this patch
        }
        // Every cluster, the DAG's roots included, must itself be fine
        // enough; where it is not, its finer clusters are drawn instead.
        let oc = to_world(inst, cl.own.xyz);
        if projected(cl.own_error * s, oc, cl.own.w * s) > thr {
            continue;
        }
        let cc = to_world(inst, cl.cull.xyz);
        if !in_frustum(cc, cl.cull.w * s) {
            continue;
        }
        let slot = atomicAdd(&counter[0], 1u);
        if slot < max_visible {
            visible[slot] = vec2<u32>(id, ci);
            atomicAdd(&counter[1], cl.tri_count);
        }
    }
}

// Turn the count into an indirect draw: 128 triangles' worth of vertices
// per visible cluster; clusters with fewer emit degenerate triangles.
@compute @workgroup_size(1)
fn finalize() {
    let n = min(atomicLoad(&counter[0]), u32(view.params.w));
    args[0] = 384u;
    args[1] = n;
    args[2] = 0u;
    args[3] = 0u;
}
