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
}

const COLORS: [[f32; 3]; 4] = [[0.69, 0.04, 0.03], [0.03, 0.16, 0.66], [0.81, 0.45, 0.01], [0.03, 0.37, 0.10]];

/// Everything a frame needs: the scene, light and camera at a moment of a race.
pub struct Setup {
    pub scene: render::Scene,
    pub light: Lighting,
    pub cam: Camera,
    pub log: Vec<String>,
}

pub fn prepare(a: &ShotArgs) -> Result<Setup, String> {
    let mut log = Vec::new();
    let t = Stopwatch::start();
    let mut settings = sideways::race::Settings::default();
    settings.stage_km = a.km;
    settings.start_at = a.at;
    settings.weather = a.weather.clone();
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
            CarPose { pos: Vec3::new(t.x, t.y, t.z), rot: Quat::from_xyzw(r.x, r.y, r.z, r.w), color: Vec3::from_array(COLORS[i % 4]), boxes: p.car.spec.boxes.clone() }
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
    // Chase camera behind the first car (src/chase_camera.gd: 5.2 m back, 2.05 m up).
    let car = &poses[0];
    let fwd = car.rot * Vec3::NEG_Z;
    let heading = Vec3::new(fwd.x, 0.0, fwd.z).normalize_or(Vec3::NEG_Z);
    let cam = Camera { pos: car.pos - heading * 5.2 + Vec3::Y * 2.05, target: car.pos + Vec3::Y * 0.9 + heading * 4.0, fov_y: 64f32.to_radians(), near: 0.1 };
    Ok(Setup { scene: built.scene, light, cam, log })
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
    let (px, stats) = renderer.render(&gpu, &cam, &light, w, h);
    println!("frame {w}x{h}: {:.0} ms wall, {} clusters / {} tris drawn, shadow {} clusters / {} tris", t.ms(), stats.clusters, stats.triangles, stats.shadow_clusters, stats.shadow_triangles);
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
