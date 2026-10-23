// The canopy volume: every tree crown splats an ellipsoid of foliage
// density into a voxel grid around the cameras. Shading traces through it
// for sky visibility and for sunlight beyond the shadow map.

struct Instance {
    r0: vec4<f32>,
    r1: vec4<f32>,
    r2: vec4<f32>,
    sphere: vec4<f32>,
    first_cluster: u32,
    cluster_count: u32,
    scale: f32,
    flags: u32,
};

struct Gi {
    vol_origin: vec4<f32>,   // xyz, w: voxel size (m)
    vol_dims: vec4<u32>,     // xyz, w: enabled
    hf: vec4<f32>,           // heightfield origin x, z, cell (m), unused
    hf_dims: vec4<u32>,
    bounce: vec4<f32>,       // irradiance of light bounced off the ground (lux)
};

@group(0) @binding(4) var<storage, read> instances: array<Instance>;
@group(1) @binding(0) var<uniform> gi: Gi;
@group(1) @binding(1) var<storage, read_write> density: array<atomic<u32>>;

@compute @workgroup_size(64)
fn fill(@builtin(global_invocation_id) gid: vec3<u32>) {
    let i = gid.x + gid.y * 65535u * 64u;
    if i >= arrayLength(&instances) {
        return;
    }
    let inst = instances[i];
    if (inst.flags & 3u) == 0u {
        return;
    }
    let r = inst.sphere.w;
    // A pine's crown: the upper part of its bounds, narrower than tall.
    var centre = inst.sphere.xyz + vec3<f32>(0.0, r * 0.25, 0.0);
    var radii = vec3<f32>(r * 0.38, r * 0.62, r * 0.38);
    var solid = 0.0;
    if (inst.flags & 2u) != 0u {
        // A solid occluder (a car body): low and flat, fully opaque.
        centre = inst.sphere.xyz;
        radii = vec3<f32>(r * 0.5, r * 0.3, r * 0.5);
        solid = 1.0;
    }
    let voxel = gi.vol_origin.w;
    let dims = vec3<i32>(gi.vol_dims.xyz);
    let lo = max(vec3<i32>(floor((centre - radii - gi.vol_origin.xyz) / voxel)), vec3<i32>(0));
    let hi = min(vec3<i32>(floor((centre + radii - gi.vol_origin.xyz) / voxel)), dims - 1);
    if any(lo > hi) {
        return;
    }
    for (var z = lo.z; z <= hi.z; z++) {
        for (var y = lo.y; y <= hi.y; y++) {
            for (var x = lo.x; x <= hi.x; x++) {
                let p = gi.vol_origin.xyz + (vec3<f32>(f32(x), f32(y), f32(z)) + 0.5) * voxel;
                let d = length((p - centre) / radii);
                if d < 1.0 {
                    let v = u32(max(1.0 - d * d, solid) * 255.0);
                    atomicMax(&density[(z * dims.y + y) * dims.x + x], v);
                }
            }
        }
    }
}
