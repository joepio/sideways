//! What gets drawn: cluster meshes, instances of them, materials, the
//! textures they sample and the sky. Built on the CPU, uploaded once.

use crate::cluster::{ClusterMesh, GpuCluster, Vertex};
use bytemuck::{Pod, Zeroable};
use glam::{Affine3A, Vec3};

/// Material flags.
pub const ALPHA_TEST: u32 = 1;
pub const TERRAIN: u32 = 2;
pub const ROAD: u32 = 4;
pub const TWO_SIDED: u32 = 8;
/// Albedo projected from world space along the dominant normal axis.
pub const TRIPLANAR: u32 = 16;

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct Material {
    /// Albedo tint (linear), multiplied with the texture.
    pub tint: [f32; 3],
    /// Texture array layer, or -1 for none.
    pub layer: i32,
    pub roughness: f32,
    pub flags: u32,
    /// World-space metres per texture repeat (triplanar/planar materials).
    pub scale: f32,
    pub _pad: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Pod, Zeroable)]
pub struct GpuInstance {
    /// Rows of the 3x4 object-to-world transform.
    pub rows: [[f32; 4]; 3],
    /// World-space bounding sphere.
    pub sphere: [f32; 4],
    pub first_cluster: u32,
    pub cluster_count: u32,
    /// Largest axis scale: errors and radii grow with it.
    pub scale: f32,
    pub _pad: u32,
}

pub struct MeshRef {
    pub first_cluster: u32,
    pub cluster_count: u32,
    pub sphere: [f32; 4],
}

/// Textures to put in the albedo array (all resized to one size).
pub struct TextureSource {
    pub name: String,
    pub rgba: image::RgbaImage,
}

#[derive(Default)]
pub struct Scene {
    pub vertices: Vec<Vertex>,
    pub cluster_verts: Vec<u32>,
    pub tris: Vec<u32>,
    pub clusters: Vec<GpuCluster>,
    pub meshes: Vec<MeshRef>,
    pub instances: Vec<GpuInstance>,
    pub materials: Vec<Material>,
    pub textures: Vec<TextureSource>,
    /// Game data for materials (Sideways: road surface per 2 m row).
    pub aux: Vec<u32>,
    /// Equirectangular HDR sky, linear RGB.
    pub sky: Option<(u32, u32, Vec<[f32; 4]>)>,
}

impl Scene {
    /// Add a mesh; returns its id for instancing.
    pub fn add_mesh(&mut self, m: &ClusterMesh) -> usize {
        let vbase = self.vertices.len() as u32;
        let cvbase = self.cluster_verts.len() as u32;
        let tbase = self.tris.len() as u32;
        let first_cluster = self.clusters.len() as u32;
        self.vertices.extend_from_slice(&m.vertices);
        self.cluster_verts.extend(m.cluster_verts.iter().map(|v| v + vbase));
        self.tris.extend_from_slice(&m.tris);
        for c in &m.clusters {
            let mut c = *c;
            c.first_vert += cvbase;
            c.first_tri += tbase;
            self.clusters.push(c);
        }
        self.meshes.push(MeshRef { first_cluster, cluster_count: m.clusters.len() as u32, sphere: m.sphere });
        self.meshes.len() - 1
    }

    pub fn add_instance(&mut self, mesh: usize, xf: Affine3A) {
        let m = &self.meshes[mesh];
        let c = xf.transform_point3(Vec3::from_slice(&m.sphere[..3]));
        let cols = xf.matrix3;
        let scale = cols.x_axis.length().max(cols.y_axis.length()).max(cols.z_axis.length());
        let mat = glam::Mat4::from(xf);
        let r = mat.transpose();
        self.instances.push(GpuInstance {
            rows: [r.x_axis.to_array(), r.y_axis.to_array(), r.z_axis.to_array()],
            sphere: [c.x, c.y, c.z, m.sphere[3] * scale],
            first_cluster: m.first_cluster,
            cluster_count: m.cluster_count,
            scale,
            _pad: 0,
        });
    }

    pub fn add_material(&mut self, m: Material) -> u32 {
        self.materials.push(m);
        (self.materials.len() - 1) as u32
    }

    /// Load an image file into the texture array; returns its layer.
    pub fn add_texture(&mut self, path: &std::path::Path) -> Result<i32, String> {
        let img = image::open(path).map_err(|e| format!("{}: {e}", path.display()))?.to_rgba8();
        self.textures.push(TextureSource { name: path.display().to_string(), rgba: img });
        Ok((self.textures.len() - 1) as i32)
    }

    /// Add an already decoded image to the texture array; returns its layer.
    pub fn add_image(&mut self, name: &str, rgba: image::RgbaImage) -> i32 {
        self.textures.push(TextureSource { name: name.to_string(), rgba });
        (self.textures.len() - 1) as i32
    }

    pub fn load_sky(&mut self, path: &std::path::Path) -> Result<(), String> {
        let img = image::open(path).map_err(|e| format!("{}: {e}", path.display()))?.to_rgba32f();
        let (w, h) = img.dimensions();
        let px = img.pixels().map(|p| [p[0], p[1], p[2], 1.0]).collect();
        self.sky = Some((w, h, px));
        Ok(())
    }

    pub fn stats(&self) -> String {
        let leaf: usize = self.clusters.iter().filter(|c| c.own_error == 0.0).map(|c| c.tri_count as usize).sum();
        format!(
            "{} meshes, {} instances, {} clusters ({} leaf triangles), {} vertices, {} textures",
            self.meshes.len(),
            self.instances.len(),
            self.clusters.len(),
            leaf,
            self.vertices.len(),
            self.textures.len()
        )
    }
}
