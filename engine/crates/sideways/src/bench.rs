//! The handling bench (tests/bench.gd): 0-100, top speed, braking, skidpad
//! and a handbrake turn on flat gravel, with the same pass ranges.

use crate::car::{Car, Ground};
use crate::physics::{HZ, Physics};
use crate::spec::Cars;
use crate::surfaces::{Surface, Surfaces};
use rapier3d::glamx::{EulerRot, Pose3, Vec3};
use serde_json::{Map, Value, json};

struct Flat;

impl Ground for Flat {
    fn road_surface(&self, _p: Vec3, hint: i64) -> (Surface, i64) {
        (Surface::Gravel, hint)
    }
    fn water_level(&self, _x: f64, _z: f64) -> f64 {
        f64::NEG_INFINITY
    }
}

pub struct BenchResult {
    pub results: Map<String, Value>,
    pub failures: Vec<String>,
    pub ticks: u64,
}

fn snap(x: f64, step: f64) -> f64 {
    (x / step).round() * step
}

pub fn run(cars: &Cars, car_id: &str) -> Result<BenchResult, String> {
    let spec = cars.get(car_id)?;
    let surfaces = Surfaces::default();
    let mut phys = Physics::new();
    phys.add_flat_ground(Surface::Gravel);
    let dt = 1.0 / HZ;
    let start = Pose3::from_translation(Vec3::new(0.0, 0.36, 0.0));
    let new_car = |phys: &mut Physics, old: Option<&Car>| -> Car {
        if let Some(o) = old {
            let w = &mut phys.world;
            w.bodies.remove(o.body, &mut w.islands, &mut w.colliders, &mut w.impulse_joints, &mut w.multibody_joints, &mut w.soft_bodies, true);
        }
        let h = phys.add_car(&spec, start, true);
        Car::new(spec.clone(), h)
    };
    let mut car = new_car(&mut phys, None);
    let mut r = Map::new();
    let mut t = 0.0f64;
    let mut phase = "rest";
    let mut marks: Vec<i32> = Vec::new();
    let mut go: Option<f64> = None;
    let mut start_pos = Vec3::ZERO;
    let mut ticks = 0u64;
    let mut skid_lat = 0.0f64;
    let mut hand_yaw = 0.0f64;
    loop {
        ticks += 1;
        if ticks > 200 * 120 {
            return Err(format!("bench stuck in phase {phase}"));
        }
        t += dt;
        let lin = car.linvel(&phys);
        let kmh = lin.length() as f64 * 3.6;
        let pos = car.pose(&phys).translation;
        let mut fresh = false;
        match phase {
            "rest" => {
                if t > 3.0 {
                    r.insert("rest_drift_cm".into(), json!(snap((pos.x as f64).hypot(pos.z as f64) * 100.0, 0.01)));
                    r.insert("ride_height".into(), json!(snap(pos.y as f64, 0.001)));
                    phase = "launch";
                    t = 0.0;
                    start_pos = pos;
                }
            }
            "launch" => {
                car.throttle = 1.0;
                car.steer_input = 0.0;
                for target in [60, 100, 160] {
                    if kmh >= target as f64 && !marks.contains(&target) {
                        marks.push(target);
                        r.insert(format!("0-{target}_s"), json!(snap(t, 0.01)));
                    }
                }
                if t > 45.0 {
                    r.insert("top_kmh".into(), json!(snap(kmh, 0.1)));
                    r.insert("top_gear".into(), json!(car.gear));
                    r.insert("shifts".into(), json!(car.stats.shifts));
                    phase = "to100";
                    fresh = true;
                }
            }
            "to100" => {
                car.throttle = 1.0;
                if t > 1.0 && kmh >= 100.0 {
                    phase = "brake";
                    start_pos = pos;
                    t = 0.0;
                }
            }
            "brake" => {
                car.throttle = 0.0;
                car.brake = 1.0;
                if kmh < 0.5 {
                    r.insert("brake_100_m".into(), json!(snap(pos.distance(start_pos) as f64, 0.1)));
                    r.insert("brake_100_s".into(), json!(snap(t, 0.01)));
                    phase = "skid";
                    fresh = true;
                }
            }
            "skid" => {
                let speed = lin.length() as f64;
                let want = (30.0 + (t - 6.0).max(0.0) * 4.0) / 3.6;
                car.throttle = ((want - speed) * 0.5).clamp(0.0, 1.0);
                car.steer_input = if t > 4.0 { -0.5 } else { 0.0 };
                if t > 6.0 {
                    let yaw = car.angvel(&phys).y as f64;
                    skid_lat = skid_lat.max(snap((yaw * speed).abs() / 9.81, 0.01));
                }
                if t > 22.0 {
                    r.insert("skid_lat_g".into(), json!(skid_lat));
                    r.insert("skid_slip_deg".into(), json!(snap(car.stats.max_slip_angle, 0.1)));
                    phase = "hand";
                    fresh = true;
                }
            }
            "hand" => match go {
                None => {
                    car.throttle = 1.0;
                    if kmh > 60.0 {
                        go = Some(t);
                    }
                }
                Some(g0) => {
                    let since = t - g0;
                    car.throttle = 0.0;
                    car.handbrake = if since < 0.8 { 1.0 } else { 0.0 };
                    car.steer_input = if since < 1.5 { -1.0 } else { 0.0 };
                    hand_yaw = hand_yaw.max(snap((car.angvel(&phys).y as f64).abs(), 0.01));
                    if since > 3.0 {
                        let (yaw, _, _) = car.pose(&phys).rotation.to_euler(EulerRot::YXZ);
                        r.insert("hand_yaw_max".into(), json!(hand_yaw));
                        r.insert("hand_heading_deg".into(), json!(snap((yaw as f64).to_degrees().abs(), 1.0)));
                        break;
                    }
                }
            },
            _ => unreachable!(),
        }
        if fresh {
            car = new_car(&mut phys, Some(&car));
            t = 0.0;
            marks.clear();
        }
        car.integrate(&mut phys, &Flat, &surfaces, dt);
        phys.step();
    }
    let mut failures = Vec::new();
    for (key, lo, hi) in [
        ("rest_drift_cm", 0.0, 3.0),
        ("0-100_s", 3.5, 6.5),
        ("top_kmh", 175.0, 215.0),
        ("brake_100_m", 35.0, 60.0),
        ("skid_lat_g", 0.75, 1.25),
        ("hand_heading_deg", 60.0, 180.0),
    ] {
        let v = r.get(key).and_then(|v| v.as_f64()).unwrap_or(f64::NAN);
        if !(v >= lo && v <= hi) {
            failures.push(format!("{key} = {v}, want {lo}..{hi}"));
        }
    }
    Ok(BenchResult { results: r, failures, ticks })
}
