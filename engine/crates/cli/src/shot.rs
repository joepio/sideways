//! `sideways shot out.png`: run the race to a tick, then render one chase
//! view offscreen. Prints what the frame cost and what it drew.

use crate::visuals::{self, CarPose};
use glam::{Quat, Vec3};
use kern::Sim;
use render::{Camera, Gpu, Lighting, Renderer, Stopwatch};

pub struct ShotArgs {
    pub out: String,
    pub seed: u64,
    pub km: f64,
    pub at: f64,
    pub frames: u64,
    pub size: (u32, u32),
    pub weather: Option<String>,
    pub lod_pixels: f32,
    pub picks: Vec<(u32, u32)>,
    /// `--set key=value` light overrides.
    pub sets: Vec<String>,
    /// Split-screen views, one bot car each (no rivals when more than one).
    pub views: usize,
    /// Frames rendered for TAA to converge (the camera holds still); 1: no TAA.
    pub taa_frames: u32,
}

/// main.gd's player colours (sRGB).
const COLORS: [u32; 8] = [0xd8342c, 0x2f6fd6, 0xe8b21f, 0x2fa35a, 0x8a4fd1, 0xe46c1c, 0xd94f9a, 0x8c969e];

/// Car `i`'s paint, linear: players take COLORS[i], bots COLORS[(i + 3) % 8]
/// (main.gd), darkened and desaturated like car_model.gd's real paint.
fn paint(i: usize, humans: usize) -> Vec3 {
    let hex = COLORS[if i < humans { i } else { (i + 3) % 8 } % 8];
    let c = Vec3::new(((hex >> 16) & 255) as f32, ((hex >> 8) & 255) as f32, (hex & 255) as f32) / 255.0;
    let v = c.max_element();
    // HSV: s *= 0.72, v *= 0.72. Scaling saturation pulls each channel towards v.
    let c = (Vec3::splat(v) - (Vec3::splat(v) - c) * 0.72) * 0.72;
    let lin = |x: f32| if x <= 0.04045 { x / 12.92 } else { ((x + 0.055) / 1.055).powf(2.4) };
    Vec3::new(lin(c.x), lin(c.y), lin(c.z))
}

/// Everything a frame needs: the scene, light and camera at a moment of a race.
pub struct Setup {
    pub scene: render::Scene,
    pub mesh_names: Vec<String>,
    pub light: Lighting,
    pub cam: Camera,
    /// One chase camera per car.
    pub cams: Vec<Camera>,
    pub log: Vec<String>,
}

pub fn prepare(a: &ShotArgs) -> Result<Setup, String> {
    let mut log = Vec::new();
    let t = Stopwatch::start();
    let mut settings = sideways::race::Settings::default();
    settings.stage_km = a.km;
    settings.start_at = a.at;
    settings.weather = a.weather.clone();
    if a.views > 1 {
        settings.bots = a.views;
        settings.rivals = 0;
    }
    let cars = sideways::spec::Cars::load(None).expect("cars");
    let mut race = sideways::race::Race::new(a.seed, settings, cars);
    let mut timings = kern::Timings::default();
    for _ in 1..a.frames {
        race.step(&mut timings);
    }
    log.push(format!("sim to tick {}: {:.0} ms", a.frames, t.ms()));
    let poses: Vec<CarPose> = race
        .players
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let pose = p.car.pose(&race.phys);
            let t = pose.translation;
            let r = pose.rotation;
            let wheels = p
                .car
                .wheels
                .iter()
                .map(|w| crate::car_model::Wheel { anchor: Vec3::new(w.anchor.x, w.anchor.y, w.anchor.z), compression: w.compression as f32, steer: w.steer as f32, spin: w.spin as f32 })
                .collect();
            CarPose {
                pos: Vec3::new(t.x, t.y, t.z),
                rot: Quat::from_xyzw(r.x, r.y, r.z, r.w),
                color: paint(i, a.views.max(1)),
                boxes: p.car.spec.boxes.clone(),
                model: p.car.spec.model.clone(),
                ride: p.car.spec.ride as f32,
                wheels,
            }
        })
        .collect();
    let t = Stopwatch::start();
    let built = visuals::build(&race.stage, &poses)?;
    log.extend(built.log.iter().map(|l| format!("  {l}")));
    log.push(format!("scene: {:.0} ms", t.ms()));
    let mut light = Lighting::default();
    light.lod_pixels = a.lod_pixels;
    match race.weather {
        "overcast" => {
            light.sun_lux = 25_000.0;
            light.sky_lux = 14_000.0;
            light.shadow_strength = 0.6;
            light.ev100 = 12.5;
            light.fog_start = 50.0;
            light.fog_end = 420.0;
        }
        "mist" => {
            light.sun_lux = 30_000.0;
            light.sky_lux = 15_000.0;
            light.shadow_strength = 0.7;
            light.ev100 = 12.7;
            light.fog_start = 0.0;
            light.fog_end = 1e9;
            light.fog_density = 0.011;
        }
        "wet" => {
            light.sun_lux = 20_000.0;
            light.sky_lux = 12_000.0;
            light.shadow_strength = 0.5;
            light.ev100 = 12.2;
            light.fog_start = 30.0;
            light.fog_end = 320.0;
        }
        _ => {}
    }
    for kv in &a.sets {
        light.set(kv)?;
    }
    // Chase cameras (src/chase_camera.gd: 5.2 m back, 2.05 m up).
    let cams: Vec<Camera> = poses
        .iter()
        .map(|car| {
            let fwd = car.rot * Vec3::NEG_Z;
            let heading = Vec3::new(fwd.x, 0.0, fwd.z).normalize_or(Vec3::NEG_Z);
            Camera { pos: car.pos - heading * 5.2 + Vec3::Y * 2.05, target: car.pos + Vec3::Y * 0.9 + heading * 4.0, fov_y: 64f32.to_radians(), near: 0.1 }
        })
        .collect();
    Ok(Setup { scene: built.scene, mesh_names: built.mesh_names, light, cam: cams[0], cams, log })
}

pub fn run(a: &ShotArgs) -> i32 {
    let setup = match prepare(a) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("shot: {e}");
            return 1;
        }
    };
    for l in &setup.log {
        println!("{l}");
    }
    let t = Stopwatch::start();
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(e) => {
            eprintln!("shot: {e}");
            return 1;
        }
    };
    let renderer = Renderer::new(&gpu, &setup.scene, &setup.light);
    println!("gpu upload ({}): {:.0} ms", gpu.info.name, t.ms());
    let (cam, light) = (setup.cam, setup.light.clone());
    let (w, h) = a.size;
    let t = Stopwatch::start();
    let _ = cam;
    let views = view_rects(&setup.cams, a.views, w, h);
    let mut light = light;
    if a.taa_frames <= 1 {
        light.taa = 0.0;
    }
    let mut first_ms = 0.0;
    for _ in 1..a.taa_frames.max(1) {
        renderer.render_views(&gpu, &views, &light, w, h, &[]);
        if first_ms == 0.0 {
            first_ms = t.ms();
        }
    }
    let (px, stats) = renderer.render_views(&gpu, &views, &light, w, h, &a.picks);
    for (k, p) in stats.picks.iter().enumerate() {
        let (x, y) = a.picks[k];
        match p {
            None => println!("pick {x},{y}: sky"),
            Some((inst, cluster, tri)) => {
                let i = &setup.scene.instances[*inst as usize];
                let c = &setup.scene.clusters[*cluster as usize];
                let mesh = setup.scene.meshes.iter().position(|m| m.first_cluster == i.first_cluster).unwrap_or(usize::MAX);
                let packed = setup.scene.tris[(c.first_tri + tri) as usize];
                let corners: Vec<String> = (0..3)
                    .map(|k| {
                        let v = setup.scene.vertices[setup.scene.cluster_verts[(c.first_vert + ((packed >> (8 * k)) & 0xff)) as usize] as usize].pos;
                        let w = [i.rows[0][0] * v[0] + i.rows[0][1] * v[1] + i.rows[0][2] * v[2] + i.rows[0][3], i.rows[1][0] * v[0] + i.rows[1][1] * v[1] + i.rows[1][2] * v[2] + i.rows[1][3], i.rows[2][0] * v[0] + i.rows[2][1] * v[1] + i.rows[2][2] * v[2] + i.rows[2][3]];
                        format!("({:.1},{:.2},{:.1})", w[0], w[1], w[2])
                    })
                    .collect();
                println!("pick {x},{y}: instance {inst} mesh {mesh} ({}) material {} cluster {cluster} own_err {:.3} tri {}", setup.mesh_names.get(mesh).cloned().unwrap_or_default(), c.material, c.own_error, corners.join(" "));
            }
        }
    }
    let frames = a.taa_frames.max(1);
    println!("{frames} frame(s) {w}x{h}: {:.0} ms wall (first {:.0} ms), {} clusters / {} tris drawn, shadow {} clusters / {} tris", t.ms(), first_ms, stats.clusters, stats.triangles, stats.shadow_clusters, stats.shadow_triangles);
    if !stats.gpu_ms.is_empty() {
        println!("  gpu: {}", stats.gpu_ms.iter().map(|(n, ms)| format!("{n} {ms:.1} ms")).collect::<Vec<_>>().join(", "));
    }
    match render::write_png(std::path::Path::new(&a.out), w, h, &px) {
        Ok(()) => {
            println!("shot: {}", a.out);
            0
        }
        Err(e) => {
            eprintln!("shot: {e}");
            1
        }
    }
}

/// The first `n` chase cameras laid out as Godot's split screen.
pub fn view_rects(cams: &[Camera], n: usize, w: u32, h: u32) -> Vec<render::ViewRect> {
    render::split_rects(n.max(1), w, h)
        .into_iter()
        .zip(cams.iter().cycle())
        .map(|((x, y, vw, vh), cam)| render::ViewRect { cam: *cam, x, y, w: vw, h: vh })
        .collect()
}
