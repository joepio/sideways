//! The bot driver (src/ai.gd): pure pursuit on the centre line and a speed
//! plan from the curvature ahead, with braking distance.

use crate::car::Car;
use crate::physics::Physics;
use crate::stage::{STEP, Stage};
use crate::surfaces::Surfaces;
use gdcompat::math::v3;
use rapier3d::glamx::Vec3;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct RallyAi {
    pub pace: f64,
    pub hint: i64,
    pub stuck: f64,
    #[serde(skip)]
    pub plan: Vec<f32>,
}

/// Godot's `Vector3.signed_angle_to`.
pub fn signed_angle(a: Vec3, b: Vec3, axis: Vec3) -> f64 {
    let c = a.cross(b);
    let unsigned = (c.length() as f64).atan2(a.dot(b) as f64);
    if c.dot(axis) < 0.0 { -unsigned } else { unsigned }
}

fn g(v: gdcompat::math::V3) -> Vec3 {
    Vec3::new(v.x, v.y, v.z)
}

impl RallyAi {
    pub fn new(stage: &Stage, surfaces: &Surfaces, pace: f64) -> RallyAi {
        let mut ai = RallyAi { pace, hint: -1, stuck: 0.0, plan: vec![] };
        ai.replan(stage, surfaces);
        ai
    }

    /// Corner speeds from the radius, then a backward pass for braking.
    pub fn replan(&mut self, stage: &Stage, surfaces: &Surfaces) {
        let n = stage.points.len();
        let mu = 0.78 * self.pace;
        let grip_at = |i: usize| surfaces.get(stage.road_surface_at(i as f64 * STEP)).mu;
        self.plan = (0..n)
            .map(|i| {
                let mut k = 0.0f64;
                for j in i.saturating_sub(4)..(i + 5).min(n) {
                    k = k.max((stage.curvature[j] as f64).abs());
                }
                let grip = grip_at(i).min(1.0);
                (mu * grip * 9.81 / k.max(1e-4)).sqrt().min(58.0) as f32
            })
            .collect();
        let decel = 6.0 * self.pace;
        for i in (0..n.saturating_sub(1)).rev() {
            let grip = grip_at(i).min(grip_at(i + 1)).min(1.0);
            let next = self.plan[i + 1] as f64;
            self.plan[i] = (self.plan[i] as f64).min((next * next + 2.0 * decel * grip * STEP).sqrt()) as f32;
        }
    }

    pub fn drive(&mut self, car: &mut Car, phys: &Physics, stage: &Stage, dt: f64) {
        let pose = car.pose(phys);
        let pos = pose.translation;
        let loc = stage.locate(v3(pos.x, pos.y, pos.z), self.hint);
        if loc.index < 0 {
            car.throttle = 0.3;
            car.steer_input = 0.0;
            return;
        }
        self.hint = loc.index;
        let lin = car.linvel(phys);
        let v = lin.length() as f64;
        let along = loc.along;
        let look = 7.0 + v * 0.55;
        let mut target = g(stage.point_at(along + look));
        let k_ahead = stage.curvature_at(along + look);
        let d = stage.dir_at(along + look);
        let right = Vec3::new(-d.z, 0.0, d.x);
        target -= right * ((k_ahead * 60.0).clamp(-1.0, 1.0) * stage.width_at(along + look) * 0.35) as f32;
        let mut fwd = pose.rotation * Vec3::NEG_Z;
        fwd.y = 0.0;
        let mut to = target - pos;
        to.y = 0.0;
        let angle = signed_angle(fwd, to, Vec3::Y);
        let mut vel = lin;
        vel.y = 0.0;
        let slip = if v > 4.0 { signed_angle(fwd, vel, Vec3::Y) } else { 0.0 };
        car.steer_input = (-(angle * 2.1 + slip * 0.6)).clamp(-1.0, 1.0);
        let row = (((along + v * 0.35) / STEP) as i64).clamp(0, self.plan.len() as i64 - 1) as usize;
        let err = self.plan[row] as f64 - v;
        car.throttle = if err > -1.0 { (err * 0.35 + 0.25).clamp(0.0, 1.0) } else { 0.0 };
        car.brake = if err < -1.5 { (-err * 0.25).clamp(0.0, 1.0) } else { 0.0 };
        car.handbrake = if stage.curvature_at(along + 6.0).abs() > 1.0 / 20.0 && v > 9.0 && slip.abs() < 0.35 { 1.0 } else { 0.0 };
        if v < 1.0 && car.throttle > 0.5 {
            self.stuck += dt;
        } else {
            self.stuck = (self.stuck - dt).max(0.0);
        }
    }
}
