//! Sideways' look as a Kern scene: terrain chunks, the road ribbon, the
//! forest (Godot's own tree meshes, exported by tools/export_meshes.gd),
//! barriers and cars, with the Poly Haven textures.

use glam::{Affine3A, Quat, Vec3};
use render::cluster::{ClusterMesh, Part, Vertex, read_kmesh};
use render::scene::{ALPHA_TEST, Material, ROAD, Scene, TERRAIN, TWO_SIDED};
use sideways::builder::{self, Chunk, N};
use sideways::stage::{GRID, Stage};
use std::path::{Path, PathBuf};

pub struct Built {
    pub scene: Scene,
    /// What each mesh id is, for picking.
    pub mesh_names: Vec<String>,
    pub log: Vec<String>,
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn v(p: Vec3, n: Vec3, uv: [f32; 2]) -> Vertex {
    Vertex { pos: p.to_array(), normal: n.to_array(), uv }
}

fn chunk_mesh(c: &Chunk, material: u32) -> ClusterMesh {
    let mut verts = Vec::with_capacity(N * N);
    for j in 0..N {
        for i in 0..N {
            let h = |i: isize, j: isize| c.heights[(j.clamp(0, N as isize - 1) as usize) * N + i.clamp(0, N as isize - 1) as usize];
            let (ii, jj) = (i as isize, j as isize);
            let dx = h(ii + 1, jj) - h(ii - 1, jj);
            let dz = h(ii, jj + 1) - h(ii, jj - 1);
            let n = Vec3::new(-dx, 2.0 * GRID as f32 * if i == 0 || i == N - 1 { 0.5 } else { 1.0 }, -dz).normalize();
            let p = c.vertex(i, j);
            verts.push(v(Vec3::new(p.x, p.y, p.z), n, [c.road_d[j * N + i], 0.0]));
        }
    }
    let mut idx = Vec::new();
    for j in 0..N - 1 {
        for i in 0..N - 1 {
            let a = (j * N + i) as u32;
            let n = N as u32;
            idx.extend_from_slice(&[a, a + n, a + 1, a + 1, a + n, a + n + 1]);
        }
    }
    ClusterMesh::build(&[Part { vertices: &verts, indices: &idx, material }])
}

fn road_mesh(s: &Stage, material: u32) -> ClusterMesh {
    let r = builder::road(s);
    let cols = r.cols;
    let rows = r.verts.len() / cols;
    let mut verts = Vec::with_capacity(r.verts.len());
    for i in 0..rows {
        for c in 0..cols {
            let k = i * cols + c;
            let at = |k: usize| Vec3::new(r.verts[k].x, r.verts[k].y, r.verts[k].z);
            let along = at(if i + 1 < rows { k + cols } else { k }) - at(if i > 0 { k - cols } else { k });
            let side = at(if c + 1 < cols { k + 1 } else { k }) - at(if c > 0 { k - 1 } else { k });
            let mut n = side.cross(along).normalize_or(Vec3::Y);
            if n.y < 0.0 {
                n = -n;
            }
            verts.push(v(at(k), n, [builder::ACROSS[c] as f32, i as f32 * 2.0]));
        }
    }
    let mut idx = Vec::new();
    for t in &r.tris {
        // Godot's winding faces down; Kern draws both sides of the ground
        // anyway, but keep it consistent with the terrain.
        idx.extend_from_slice(&[t[0], t[2], t[1]]);
    }
    ClusterMesh::build(&[Part { vertices: &verts, indices: &idx, material }])
}

fn box_mesh(half: Vec3, material: u32) -> ClusterMesh {
    let mut verts = Vec::new();
    let mut idx = Vec::new();
    for axis in 0..3 {
        for sign in [-1.0f32, 1.0] {
            let mut n = Vec3::ZERO;
            n[axis] = sign;
            let (u, w) = ((axis + 1) % 3, (axis + 2) % 3);
            let base = verts.len() as u32;
            for (a, b) in [(-1.0f32, -1.0f32), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                let mut p = n * half[axis];
                p[u] = a * half[u];
                p[w] = b * half[w];
                verts.push(v(p, n, [a * 0.5 + 0.5, b * 0.5 + 0.5]));
            }
            let quad = if sign > 0.0 { [0, 1, 2, 0, 2, 3] } else { [0, 2, 1, 0, 3, 2] };
            idx.extend(quad.iter().map(|q| base + q));
        }
    }
    ClusterMesh::build(&[Part { vertices: &verts, indices: &idx, material }])
}

/// A car: two boxes from its collision shape until the glTF bodies load.
fn car_mesh(boxes: &[[f64; 6]], material: u32) -> ClusterMesh {
    let mut verts = Vec::new();
    let mut idx = Vec::new();
    for b in boxes {
        let m = box_mesh(Vec3::new(b[0] as f32, b[1] as f32, b[2] as f32) * 0.5, material);
        // box_mesh built clusters; rebuild from its vertices instead.
        let base = verts.len() as u32;
        for vx in &m.vertices {
            let mut vx = *vx;
            vx.pos = [vx.pos[0] + b[3] as f32, vx.pos[1] + b[4] as f32, vx.pos[2] + b[5] as f32];
            verts.push(vx);
        }
        for c in &m.clusters {
            for t in 0..c.tri_count {
                let p = m.tris[(c.first_tri + t) as usize];
                for k in 0..3 {
                    idx.push(base + m.cluster_verts[(c.first_vert + ((p >> (8 * k)) & 0xff)) as usize]);
                }
            }
        }
    }
    ClusterMesh::build(&[Part { vertices: &verts, indices: &idx, material }])
}

pub struct CarPose {
    pub pos: Vec3,
    pub rot: Quat,
    pub color: Vec3,
    pub boxes: Vec<[f64; 6]>,
    /// res://assets/cars/x.glb, or empty for a box car.
    pub model: String,
    pub ride: f32,
    pub wheels: Vec<crate::car_model::Wheel>,
}

pub fn build(stage: &Stage, cars: &[CarPose]) -> Result<Built, String> {
    let mut log = Vec::new();
    let t = std::time::Instant::now();
    let mut scene = Scene::default();
    let r = root();
    let tex = |scene: &mut Scene, rel: &str| scene.add_texture(&r.join(rel));
    // Terrain layers, in the order shade.wgsl blends them.
    let t0 = tex(&mut scene, "assets/textures/forest_ground_04_albedo.jpg")?;
    tex(&mut scene, "assets/textures/forrest_ground_03_albedo.jpg")?;
    tex(&mut scene, "assets/textures/grass_ground_albedo.jpg")?;
    tex(&mut scene, "assets/textures/rock_face_03_albedo.jpg")?;
    let gravel = tex(&mut scene, "assets/textures/gravel_ground_01_albedo.jpg")?;
    tex(&mut scene, "assets/textures/forest_ground_04_albedo.jpg")?;
    let trunk_a = tex(&mut scene, "assets/trees/trunk_a_albedo.jpg")?;
    let trunk_b = tex(&mut scene, "assets/trees/trunk_b_albedo.jpg")?;
    let bark = tex(&mut scene, "assets/trees/bark_albedo.jpg")?;
    let crown = tex(&mut scene, "assets/trees/authored_pine_albedo.png")?;
    scene.load_sky(&r.join("assets/sky/sky_2k.hdr"))?;
    let m = |tint: [f32; 3], layer: i32, flags: u32, scale: f32| Material { tint, layer, roughness: 0.9, flags, scale, _pad: 0.0 };
    let terrain_mat = scene.add_material(m([1.0, 1.0, 1.0], t0, TERRAIN, 4.0));
    let road_mat = scene.add_material(m([1.0, 1.0, 1.0], gravel, ROAD, 3.0));
    let trunk_a_mat = scene.add_material(m([1.0, 1.0, 1.0], trunk_a, 0, 1.0));
    let trunk_b_mat = scene.add_material(m([1.0, 1.0, 1.0], trunk_b, 0, 1.0));
    let bark_mat = scene.add_material(m([1.0, 1.0, 1.0], bark, 0, 1.0));
    let crown_mat = scene.add_material(m([1.0, 1.0, 1.0], crown, ALPHA_TEST | TWO_SIDED, 1.0));
    let barrier_mat = scene.add_material(m([0.55, 0.56, 0.57], -1, 0, 1.0));
    log.push(format!("textures and sky: {:.0} ms", t.elapsed().as_secs_f64() * 1e3));

    // Terrain and trees, chunk by chunk.
    let t = std::time::Instant::now();
    let cells = builder::chunk_cells(stage);
    let chunks: Vec<Chunk> = std::thread::scope(|s| {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        let per = cells.len().div_ceil(threads);
        let handles: Vec<_> = cells.chunks(per).map(|part| s.spawn(move || part.iter().map(|c| builder::terrain_chunk(stage, *c)).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    log.push(format!("terrain data: {:.0} ms", t.elapsed().as_secs_f64() * 1e3));
    let t = std::time::Instant::now();
    let meshes: Vec<ClusterMesh> = std::thread::scope(|s| {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
        let per = chunks.len().div_ceil(threads);
        let handles: Vec<_> = chunks.chunks(per).map(|part| s.spawn(move || part.iter().map(|c| chunk_mesh(c, terrain_mat)).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect()
    });
    let mut mesh_names = Vec::new();
    for (k, mesh) in meshes.iter().enumerate() {
        let id = scene.add_mesh(mesh);
        scene.add_instance(id, Affine3A::IDENTITY);
        mesh_names.push(format!("terrain chunk {:?}", chunks[k].cell));
    }
    let rm = road_mesh(stage, road_mat);
    let road = scene.add_mesh(&rm);
    mesh_names.push("road".into());
    scene.add_instance(road, Affine3A::IDENTITY);
    log.push(format!("terrain + road clusters: {:.0} ms", t.elapsed().as_secs_f64() * 1e3));

    // Trees: three variants, Godot's near meshes.
    let t = std::time::Instant::now();
    let mut tree_meshes = Vec::new();
    for variant in ["a", "b", "c"] {
        let path = r.join(format!("engine/assets/fir_{variant}_near.kmesh"));
        let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e} (run tools/export_meshes.gd)", path.display()))?;
        let surfaces = read_kmesh(&bytes)?;
        let parts: Vec<(Vec<Vertex>, Vec<u32>, u32)> = surfaces
            .into_iter()
            .map(|(name, verts, idx)| {
                let mat = if name.contains("trunk_b") {
                    trunk_b_mat
                } else if name.contains("trunk") {
                    trunk_a_mat
                } else if name.contains("bark") {
                    bark_mat
                } else {
                    crown_mat
                };
                (verts, idx, mat)
            })
            .collect();
        let p: Vec<Part> = parts.iter().map(|(v, i, m)| Part { vertices: v, indices: i, material: *m }).collect();
        let cm = ClusterMesh::build(&p);
        log.push(format!("fir_{variant}: {} leaf tris, {} root tris, {} clusters, {} levels", cm.leaf_triangles(), cm.root_triangles(), cm.clusters.len(), cm.levels));
        tree_meshes.push(scene.add_mesh(&cm));
        mesh_names.push(format!("fir_{variant}"));
    }
    let mut trees = 0;
    for c in &chunks {
        for (k, spot) in c.trees.iter().enumerate() {
            let variant = ((spot.pos.0 * 7.31 + spot.pos.2 * 3.17).abs() as usize + k) % 3;
            let xf = Affine3A::from_scale_rotation_translation(
                Vec3::new(spot.scale, spot.scale_y, spot.scale),
                Quat::from_rotation_y(spot.yaw),
                Vec3::new(spot.pos.0, spot.pos.1, spot.pos.2),
            );
            scene.add_instance(tree_meshes[variant], xf);
            trees += 1;
        }
    }
    log.push(format!("trees: {trees} instances, {:.0} ms", t.elapsed().as_secs_f64() * 1e3));

    // Barriers along the ledges and bridge rails.
    for b in builder::barriers(stage) {
        let mesh = box_mesh(Vec3::new(b.half.x, b.half.y, b.half.z), barrier_mat);
        let id = scene.add_mesh(&mesh);
        mesh_names.push("barrier".into());
        let rot = Quat::from_rotation_arc(Vec3::NEG_Z, Vec3::new(b.along.x, b.along.y, b.along.z).normalize_or(Vec3::NEG_Z));
        scene.add_instance(id, Affine3A::from_rotation_translation(rot, Vec3::new(b.centre.x, b.centre.y, b.centre.z)));
    }
    let mut car_textures = std::collections::HashMap::new();
    for car in cars {
        let pose = Affine3A::from_rotation_translation(car.rot, car.pos);
        if let Some(rel) = car.model.strip_prefix("res://") {
            let t = std::time::Instant::now();
            let before = scene.meshes.len();
            let meshes = crate::car_model::load(&mut scene, &r.join(rel), car.color.to_array(), &mut car_textures)?;
            for k in before..scene.meshes.len() {
                mesh_names.push(format!("car {rel} part {}", k - before));
            }
            crate::car_model::place(&mut scene, &meshes, pose, car.ride, &car.wheels);
            log.push(format!("car {rel}: {:.0} ms", t.elapsed().as_secs_f64() * 1e3));
        } else {
            let mat = scene.add_material(m(car.color.to_array(), -1, 0, 1.0));
            let id = scene.add_mesh(&car_mesh(&car.boxes, mat));
            mesh_names.push("car box".into());
            scene.add_instance(id, pose);
        }
    }
    log.push(scene.stats());
    Ok(Built { scene, mesh_names, log })
}
