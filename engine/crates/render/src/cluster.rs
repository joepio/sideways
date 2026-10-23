//! Nanite-style geometry: every mesh becomes clusters of up to 128
//! triangles arranged in a LOD DAG (meshoptimizer's clusterlod). Groups of
//! clusters are simplified together with their borders locked, so any cut
//! through the DAG is crack-free. At run time a cluster is drawn when its
//! own error projects to at most a pixel and its group's coarser
//! replacement would project to more: one cluster per patch of surface,
//! each at the detail the screen needs.

use bytemuck::{Pod, Zeroable};
use meshopt::clusterlod::{ClodMesh, clod_build, clod_default_config, clod_local_indices};

pub const MAX_TRIS: usize = 128;

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Vertex {
    pub pos: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
}

/// One cluster as the GPU sees it (80 bytes).
#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct GpuCluster {
    /// Culling sphere: centre and radius.
    pub cull: [f32; 4],
    /// The group this cluster is in, simplified: if that projects to at most
    /// the threshold, a coarser cluster covers this patch instead.
    pub parent: [f32; 4],
    /// This cluster's own error sphere (the group it was simplified from).
    pub own: [f32; 4],
    pub parent_error: f32,
    pub own_error: f32,
    pub first_tri: u32,
    pub tri_count: u32,
    pub first_vert: u32,
    pub material: u32,
    pub depth: u32,
    pub _pad: u32,
}

/// A mesh part with one material.
pub struct Part<'a> {
    pub vertices: &'a [Vertex],
    pub indices: &'a [u32],
    pub material: u32,
}

/// Cluster data for a mesh, ready to append to the scene buffers. Indices
/// in `clusters` are local to these arrays; the scene rebases them.
#[derive(Default)]
pub struct ClusterMesh {
    pub vertices: Vec<Vertex>,
    /// Per cluster, the mesh vertices it uses (cluster-local index -> vertex).
    pub cluster_verts: Vec<u32>,
    /// Per triangle, three cluster-local indices packed in one u32.
    pub tris: Vec<u32>,
    pub clusters: Vec<GpuCluster>,
    /// Bounding sphere of the whole mesh.
    pub sphere: [f32; 4],
    pub levels: u32,
}

impl ClusterMesh {
    pub fn build(parts: &[Part]) -> ClusterMesh {
        let mut out = ClusterMesh::default();
        for part in parts {
            if part.indices.is_empty() {
                continue;
            }
            let base = out.vertices.len() as u32;
            out.vertices.extend_from_slice(part.vertices);
            let positions: &[u8] = bytemuck::cast_slice(part.vertices);
            let adapter = meshopt::VertexDataAdapter::new(positions, std::mem::size_of::<Vertex>(), 0).expect("vertex adapter");
            let mesh = ClodMesh::new(part.indices, &adapter);
            let mut config = clod_default_config(MAX_TRIS);
            config.max_triangles = MAX_TRIS;
            let mut groups: Vec<[f32; 5]> = Vec::new(); // simplified bounds per group
            let mut pending: Vec<(usize, i32, Vec<u32>, [f32; 4])> = Vec::new(); // (group, refined, indices, cull sphere)
            clod_build(config, &mesh, |group, clusters| {
                let gid = groups.len();
                let b = group.simplified;
                groups.push([b.center[0], b.center[1], b.center[2], b.radius, b.error]);
                for c in clusters {
                    let cb = c.bounds;
                    pending.push((gid, c.refined, c.indices.to_vec(), [cb.center[0], cb.center[1], cb.center[2], cb.radius]));
                }
                out.levels = out.levels.max(group.depth as u32 + 1);
                gid as i32
            });
            for (gid, refined, indices, cull) in pending {
                let g = groups[gid];
                let (own, own_error) = if refined < 0 {
                    ([cull[0], cull[1], cull[2], cull[3]], 0.0)
                } else {
                    let r = groups[refined as usize];
                    ([r[0], r[1], r[2], r[3]], r[4])
                };
                let (verts, local) = clod_local_indices(&indices);
                let first_vert = out.cluster_verts.len() as u32;
                out.cluster_verts.extend(verts.iter().map(|v| v + base));
                let first_tri = out.tris.len() as u32;
                for t in local.chunks(3) {
                    out.tris.push(t[0] as u32 | (t[1] as u32) << 8 | (t[2] as u32) << 16);
                }
                out.clusters.push(GpuCluster {
                    cull,
                    parent: [g[0], g[1], g[2], g[3]],
                    own,
                    parent_error: g[4],
                    own_error,
                    first_tri,
                    tri_count: (local.len() / 3) as u32,
                    first_vert,
                    material: part.material,
                    depth: 0,
                    _pad: 0,
                });
            }
        }
        out.sphere = bounding_sphere(&out.vertices);
        out
    }

    /// Triangles at full detail (the DAG's leaves).
    pub fn leaf_triangles(&self) -> usize {
        self.clusters.iter().filter(|c| c.own_error == 0.0).map(|c| c.tri_count as usize).sum()
    }
}

fn bounding_sphere(v: &[Vertex]) -> [f32; 4] {
    if v.is_empty() {
        return [0.0; 4];
    }
    let mut lo = [f32::MAX; 3];
    let mut hi = [f32::MIN; 3];
    for p in v {
        for k in 0..3 {
            lo[k] = lo[k].min(p.pos[k]);
            hi[k] = hi[k].max(p.pos[k]);
        }
    }
    let c = [(lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5];
    let r = v.iter().map(|p| ((p.pos[0] - c[0]).powi(2) + (p.pos[1] - c[1]).powi(2) + (p.pos[2] - c[2]).powi(2)).sqrt()).fold(0.0f32, f32::max);
    [c[0], c[1], c[2], r]
}

/// Read a .kmesh written by tools/export_meshes.gd: (material name, vertices, indices) per surface.
pub fn read_kmesh(bytes: &[u8]) -> Result<Vec<(String, Vec<Vertex>, Vec<u32>)>, String> {
    let mut at = 0usize;
    let u32_ = |at: &mut usize| -> Result<u32, String> {
        let b = bytes.get(*at..*at + 4).ok_or("kmesh truncated")?;
        *at += 4;
        Ok(u32::from_le_bytes(b.try_into().unwrap()))
    };
    if bytes.get(0..4) != Some(b"KMSH") {
        return Err("not a kmesh".into());
    }
    at += 4;
    let surfaces = u32_(&mut at)?;
    let mut out = Vec::new();
    for _ in 0..surfaces {
        let n = u32_(&mut at)? as usize;
        let name = String::from_utf8_lossy(&bytes[at..at + n]).to_string();
        at += n;
        let vc = u32_(&mut at)? as usize;
        let ic = u32_(&mut at)? as usize;
        let f = |at: usize, k: usize| f32::from_le_bytes(bytes[at + k * 4..at + k * 4 + 4].try_into().unwrap());
        let mut verts = vec![Vertex { pos: [0.0; 3], normal: [0.0; 3], uv: [0.0; 2] }; vc];
        for (i, v) in verts.iter_mut().enumerate() {
            v.pos = [f(at, i * 3), f(at, i * 3 + 1), f(at, i * 3 + 2)];
        }
        at += vc * 12;
        for (i, v) in verts.iter_mut().enumerate() {
            v.normal = [f(at, i * 3), f(at, i * 3 + 1), f(at, i * 3 + 2)];
        }
        at += vc * 12;
        for (i, v) in verts.iter_mut().enumerate() {
            v.uv = [f(at, i * 2), f(at, i * 2 + 1)];
        }
        at += vc * 8;
        let mut idx = Vec::with_capacity(ic);
        for _ in 0..ic {
            idx.push(u32_(&mut at)?);
        }
        out.push((name, verts, idx));
    }
    Ok(out)
}

impl ClusterMesh {
    /// Triangles drawn when the whole mesh is far away (the DAG's roots).
    pub fn root_triangles(&self) -> usize {
        self.clusters.iter().filter(|c| c.parent_error > 1e30).map(|c| c.tri_count as usize).sum()
    }
}
