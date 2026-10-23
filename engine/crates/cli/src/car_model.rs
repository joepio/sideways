//! Car bodies and wheels from the glTF models (src/car_model.gd): the body
//! in the player's colour, four wheels placed by the suspension.

use glam::{Affine3A, Quat, Vec3};
use render::cluster::{ClusterMesh, Part, Vertex};
use render::scene::{Material, Scene};
use std::collections::HashMap;

pub struct CarMeshes {
    pub body: usize,
    /// FL, FR, RL, RR (the physics' wheel order), each a mesh id.
    pub wheels: [Option<usize>; 4],
}

pub struct Wheel {
    pub anchor: Vec3,
    pub compression: f32,
    pub steer: f32,
    pub spin: f32,
}

/// Load a car glTF; `paint` colours the materials named Bodymat or Paint.
pub fn load(scene: &mut Scene, path: &std::path::Path, paint: [f32; 3], textures: &mut HashMap<String, i32>) -> Result<CarMeshes, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    // Unvalidated: the cars use EXT_texture_webp, which gltf 1.4 does not know.
    let g = gltf::Gltf::from_slice_without_validation(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    let blob = g.blob.as_deref().ok_or("glb without binary chunk")?;
    let key = path.display().to_string();
    // Materials: textured or flat, paint replaced by the player's colour.
    let mut mats = Vec::new();
    for m in g.materials() {
        let name = m.name().unwrap_or("").to_string();
        let pbr = m.pbr_metallic_roughness();
        let f = pbr.base_color_factor();
        let mut layer = -1;
        if let Some(info) = pbr.base_color_texture() {
            let tex = info.texture();
            // The image is in EXT_texture_webp's source, or the core source.
            let index = tex
                .extension_value("EXT_texture_webp")
                .and_then(|v| v.get("source"))
                .and_then(|v| v.as_u64())
                .map(|i| i as usize)
                .or_else(|| tex.source().map(|s| s.index()))
                .ok_or("texture without image")?;
            let img = g.images().nth(index).ok_or("missing image")?;
            let tkey = format!("{key}#{index}");
            layer = match textures.get(&tkey) {
                Some(l) => *l,
                None => {
                    let data = match img.source() {
                        gltf::image::Source::View { view, .. } => &blob[view.offset()..view.offset() + view.length()],
                        gltf::image::Source::Uri { .. } => return Err("external image in car glb".into()),
                    };
                    let rgba = image::load_from_memory(data).map_err(|e| format!("{tkey}: {e}"))?.to_rgba8();
                    let l = scene.add_image(&tkey, rgba);
                    textures.insert(tkey, l);
                    l
                }
            };
        }
        let painted = name.contains("Bodymat") || name.contains("Paint");
        let tint = if painted { paint } else { [f[0], f[1], f[2]] };
        // Paint as car_model.gd: metallic flake under a glossy clear coat.
        let (roughness, metal, flags) = if painted { (0.38, 0.45, render::scene::CLEARCOAT) } else { (pbr.roughness_factor(), pbr.metallic_factor(), 0) };
        mats.push(scene.add_material(Material { tint, layer: if painted { -1 } else { layer }, roughness, flags, scale: 1.0, metal }));
    }
    let mut body = None;
    let mut wheels = [None; 4];
    for node in g.nodes() {
        let Some(mesh) = node.mesh() else { continue };
        let name = node.name().unwrap_or("");
        // Wheels are built around their own centre; the body in car space.
        let (t, r, s) = node.transform().decomposed();
        let local = if name.starts_with("wheel") { Affine3A::from_scale_rotation_translation(Vec3::from(s), Quat::from_array(r), Vec3::ZERO) } else { Affine3A::from_scale_rotation_translation(Vec3::from(s), Quat::from_array(r), Vec3::from(t)) };
        let mut parts: Vec<(Vec<Vertex>, Vec<u32>, u32)> = Vec::new();
        for prim in mesh.primitives() {
            let reader = prim.reader(|_| Some(blob));
            let Some(pos) = reader.read_positions() else { continue };
            let pos: Vec<[f32; 3]> = pos.collect();
            let nrm: Vec<[f32; 3]> = reader.read_normals().map(|n| n.collect()).unwrap_or_else(|| vec![[0.0, 1.0, 0.0]; pos.len()]);
            let uv: Vec<[f32; 2]> = reader.read_tex_coords(0).map(|t| t.into_f32().collect()).unwrap_or_else(|| vec![[0.0; 2]; pos.len()]);
            let idx: Vec<u32> = reader.read_indices().map(|i| i.into_u32().collect()).unwrap_or_else(|| (0..pos.len() as u32).collect());
            let verts = pos
                .iter()
                .zip(&nrm)
                .zip(&uv)
                .map(|((p, n), t)| Vertex { pos: local.transform_point3(Vec3::from(*p)).to_array(), normal: local.transform_vector3(Vec3::from(*n)).normalize_or(Vec3::Y).to_array(), uv: *t })
                .collect();
            let mat = prim.material().index().map(|i| mats[i]).unwrap_or(mats[0]);
            parts.push((verts, idx, mat));
        }
        let p: Vec<Part> = parts.iter().map(|(v, i, m)| Part { vertices: v, indices: i, material: *m }).collect();
        let id = scene.add_mesh(&ClusterMesh::build(&p));
        let slot = ["wheel_FL", "wheel_FR", "wheel_RL", "wheel_RR"].iter().position(|w| name.starts_with(w));
        match slot {
            Some(k) => wheels[k] = Some(id),
            None if name.starts_with("body") => body = Some(id),
            None => {} // calipers: later, with the knuckles
        }
    }
    Ok(CarMeshes { body: body.ok_or("car glb has no body")?, wheels })
}

/// Instances for one car at `pose`: the body raised by `ride`, the wheels
/// where the suspension holds them, steered and rolled.
pub fn place(scene: &mut Scene, m: &CarMeshes, pose: Affine3A, ride: f32, wheels: &[Wheel]) {
    scene.add_instance(m.body, pose * Affine3A::from_translation(Vec3::Y * ride));
    scene.mark_solid();
    for (k, w) in wheels.iter().enumerate().take(4) {
        if let Some(mesh) = m.wheels[k] {
            let local = Affine3A::from_rotation_translation(Quat::from_rotation_y(w.steer) * Quat::from_rotation_x(-w.spin), w.anchor + Vec3::Y * w.compression);
            scene.add_instance(mesh, pose * local);
        }
    }
}
