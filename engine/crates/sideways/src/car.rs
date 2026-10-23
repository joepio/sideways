//! The car (src/car.gd): a rigid body with our own forces. Per wheel a
//! cylinder cast finds the ground; spring, damper, bump stop and anti-roll
//! bar give the load; a combined-slip Pacejka tyre with relaxation-length
//! slip states gives the force. Engine, automatic clutch, sequential box,
//! centre coupling (opened by the handbrake) and plated diffs run four
//! substeps per tick, couplings solved implicitly.

use crate::physics::{GROUP_WORLD, Physics, ROAD};
use crate::spec::CarSpec;
use crate::surfaces::{Surface, Surfaces, curve};
use gdcompat::math::{fposmod, move_toward, smoothstep};
use rapier3d::glamx::{Pose3, Quat, Vec3};
use rapier3d::parry::query::ShapeCastOptions;
use rapier3d::parry::shape::Cylinder;
use rapier3d::prelude::*;
use serde::Serialize;
use std::f64::consts::{PI, TAU};

pub const SUBSTEPS: usize = 4;
const V_LOW: f64 = 1.2;
const RELAX: f64 = 0.25;
const RPM: f64 = 60.0 / TAU;
const OVER_BUMP: f64 = 0.25;

/// What a car needs to know about the world beyond its colliders.
pub trait Ground {
    /// Surface of the road mesh at `p`, with a hint for the next lookup.
    fn road_surface(&self, p: Vec3, hint: i64) -> (Surface, i64);
    /// Water surface height at (x, z), -inf where dry.
    fn water_level(&self, x: f64, z: f64) -> f64;
}

#[derive(Clone, Debug, Serialize)]
pub struct Wheel {
    #[serde(skip)]
    pub anchor: Vec3,
    pub axle: usize,
    pub side: f64,
    pub radius: f64,
    pub inertia: f64,
    pub omega: f64,
    pub spin: f64,
    pub steer: f64,
    pub compression: f64,
    pub last_compression: f64,
    pub load: f64,
    pub kappa: f64,
    pub tan_alpha: f64,
    pub contact: bool,
    #[serde(skip)]
    pub point: Vec3,
    #[serde(skip)]
    pub normal: Vec3,
    pub surface: Surface,
    pub road_hint: i64,
    pub fx: f64,
    pub fy: f64,
    pub vx: f64,
    pub vy: f64,
    #[serde(skip)]
    pub wf: Vec3,
    #[serde(skip)]
    pub wr: Vec3,
    pub slide: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct CarStats {
    pub shifts: u32,
    pub air_time: f64,
    pub max_slip_angle: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Car {
    #[serde(skip)]
    pub spec: CarSpec,
    #[serde(skip)]
    pub body: RigidBodyHandle,
    pub wheels: Vec<Wheel>,
    // Driver inputs.
    pub throttle: f64,
    pub brake: f64,
    pub steer_input: f64,
    pub handbrake: f64,
    pub manual: bool,
    pub steer_assist: bool,
    pub hold: bool,
    // State.
    pub gear: i32,
    pub engine_omega: f64,
    pub shift_timer: f64,
    pub shift_target: i32,
    pub speed: f64,
    pub on_ground: u32,
    pub wading: f64,
    pub grip_scale: f64,
    pub stats: CarStats,
    reverse_hold: f64,
    shift_request: i32,
    #[serde(skip)]
    teleport: Option<Pose3>,
    engine_torque: f64,
}

fn v(x: f64, y: f64, z: f64) -> Vec3 {
    Vec3::new(x as f32, y as f32, z as f32)
}

impl Car {
    pub fn new(spec: CarSpec, body: RigidBodyHandle) -> Car {
        let half_wb = spec.wheelbase * 0.5;
        let mut wheels = Vec::new();
        for axle in 0..2 {
            let half_tr = if axle == 0 { spec.track * 0.5 } else { spec.track_rear() * 0.5 };
            for side in [-1.0, 1.0] {
                wheels.push(Wheel {
                    anchor: v(side * half_tr, spec.droop_y, if axle == 0 { -half_wb } else { half_wb }),
                    axle,
                    side,
                    radius: spec.wheel_radius,
                    inertia: spec.wheel_inertia,
                    omega: 0.0,
                    spin: 0.0,
                    steer: 0.0,
                    compression: 0.0,
                    last_compression: 0.0,
                    load: 0.0,
                    kappa: 0.0,
                    tan_alpha: 0.0,
                    contact: false,
                    point: Vec3::ZERO,
                    normal: Vec3::Y,
                    surface: Surface::Gravel,
                    road_hint: -1,
                    fx: 0.0,
                    fy: 0.0,
                    vx: 0.0,
                    vy: 0.0,
                    wf: Vec3::NEG_Z,
                    wr: Vec3::X,
                    slide: 0.0,
                });
            }
        }
        let engine_omega = spec.idle_rpm / RPM;
        Car {
            spec,
            body,
            wheels,
            throttle: 0.0,
            brake: 0.0,
            steer_input: 0.0,
            handbrake: 0.0,
            manual: false,
            steer_assist: true,
            hold: false,
            gear: 1,
            engine_omega,
            shift_timer: 0.0,
            shift_target: 1,
            speed: 0.0,
            on_ground: 0,
            wading: 0.0,
            grip_scale: 1.0,
            stats: CarStats::default(),
            reverse_hold: 0.0,
            shift_request: 0,
            teleport: None,
            engine_torque: 0.0,
        }
    }

    /// Put the car down at `pose`, at rest, before the next step.
    pub fn teleport(&mut self, phys: &mut Physics, pose: Pose3) {
        self.teleport = Some(pose);
        if let Some(b) = phys.world.bodies.get_mut(self.body) {
            b.set_position(pose, true);
            b.set_linvel(Vec3::ZERO, true);
            b.set_angvel(Vec3::ZERO, true);
        }
        for w in &mut self.wheels {
            w.omega = 0.0;
            w.kappa = 0.0;
            w.tan_alpha = 0.0;
            w.road_hint = -1;
        }
        self.gear = 1;
        self.shift_timer = 0.0;
    }

    pub fn request_shift(&mut self, dir: i32) {
        self.shift_request = dir;
    }

    pub fn rpm(&self) -> f64 {
        self.engine_omega * RPM
    }

    pub fn pose(&self, phys: &Physics) -> Pose3 {
        *phys.world.bodies[self.body].position()
    }

    pub fn linvel(&self, phys: &Physics) -> Vec3 {
        phys.world.bodies[self.body].linvel()
    }

    pub fn angvel(&self, phys: &Physics) -> Vec3 {
        phys.world.bodies[self.body].angvel()
    }

    /// `_integrate_forces`: everything this car does to its body this tick.
    pub fn integrate(&mut self, phys: &mut Physics, ground: &dyn Ground, surfaces: &Surfaces, dt: f64) {
        if let Some(pose) = self.teleport.take() {
            let b = &mut phys.world.bodies[self.body];
            b.set_position(pose, true);
            b.set_linvel(Vec3::ZERO, true);
            b.set_angvel(Vec3::ZERO, true);
            b.reset_forces(true);
            b.reset_torques(true);
            return;
        }
        let (xf, lin, ang, com) = {
            let b = &phys.world.bodies[self.body];
            (*b.position(), b.linvel(), b.angvel(), b.center_of_mass())
        };
        let up = xf.rotation * Vec3::Y;
        let fwd = xf.rotation * Vec3::NEG_Z;
        let right_axis = xf.rotation * Vec3::X;
        self.speed = lin.dot(fwd) as f64;
        self.steering(dt, lin, right_axis, fwd);
        self.gearbox(dt);
        let water = ground.water_level(xf.translation.x as f64, xf.translation.z as f64);
        let mut force = Vec3::ZERO;
        let mut torque = Vec3::ZERO;
        let mut apply = |f: Vec3, at: Vec3| {
            force += f;
            torque += (at - com).cross(f);
        };
        self.suspension(phys, ground, &xf, up, dt, water, &mut apply);

        for w in self.wheels.iter_mut() {
            if !w.contact {
                continue;
            }
            let mut wf = Quat::from_axis_angle(up, w.steer as f32) * fwd;
            wf = (wf - w.normal * wf.dot(w.normal)).normalize_or_zero();
            let wr = wf.cross(w.normal);
            let vp = lin + ang.cross(w.point - com);
            w.vx = vp.dot(wf) as f64;
            w.vy = vp.dot(wr) as f64;
            w.wf = wf;
            w.wr = wr;
        }

        let h = dt / SUBSTEPS as f64;
        let mut sum_fx = [0.0f64; 4];
        let mut sum_fy = [0.0f64; 4];
        for _ in 0..SUBSTEPS {
            for i in 0..4 {
                let (fx, fy) = tyre(&self.wheels[i], surfaces, self.grip_scale);
                self.wheels[i].fx = fx;
                self.wheels[i].fy = fy;
                sum_fx[i] += fx;
                sum_fy[i] += fy;
            }
            self.drivetrain(h, surfaces);
            for w in self.wheels.iter_mut() {
                let denom = w.vx.abs() + V_LOW;
                if w.contact {
                    w.kappa += ((w.omega * w.radius - w.vx) - denom * w.kappa) * h / RELAX;
                    w.tan_alpha += (w.vy - denom * w.tan_alpha) * h / RELAX;
                } else {
                    w.kappa = move_toward(w.kappa, 0.0, h * 8.0);
                    w.tan_alpha = move_toward(w.tan_alpha, 0.0, h * 8.0);
                }
            }
        }

        self.on_ground = 0;
        let speed_len = lin.length() as f64;
        let vdir = lin.normalize_or_zero();
        for i in 0..4 {
            let w = &mut self.wheels[i];
            w.spin = fposmod(w.spin + w.omega * dt, TAU);
            if !w.contact {
                w.slide = move_toward(w.slide, 0.0, dt * 4.0);
                continue;
            }
            self.on_ground += 1;
            let f = w.wf * (sum_fx[i] / SUBSTEPS as f64) as f32 + w.wr * (sum_fy[i] / SUBSTEPS as f64) as f32;
            apply(f, w.point);
            let surf = surfaces.get(w.surface);
            let s = ((w.kappa / surf.kappa_peak).powi(2) + (w.tan_alpha / surf.alpha_peak).powi(2)).sqrt();
            w.slide = ((s - 0.8) / 2.0).clamp(0.0, 1.0);
            // Grass and dirt drag at the car a little.
            let drag = surf.drag * speed_len.min(10.0) * 0.1 * w.load / 3000.0;
            apply(-vdir * drag as f32, w.point);
        }
        // Wading: water pushes back on the body.
        self.wading = 0.0;
        let bottom = xf.translation.y as f64 - self.spec.wheel_radius;
        if water > bottom {
            self.wading = water - bottom;
            let hv = Vec3::new(lin.x, 0.0, lin.z);
            let d = self.wading.min(0.6) as f32;
            force += -hv * hv.length() * 420.0 * d - hv * 900.0 * d;
        }
        if self.on_ground == 0 {
            self.stats.air_time += dt;
        }
        // Air.
        force += -lin * lin.length() * self.spec.drag as f32 - up * (self.spec.downforce as f32 * lin.length_squared());
        if speed_len > 5.0 && self.on_ground > 0 {
            let slip_angle = (lin.dot(right_axis) as f64).atan2(self.speed.abs()).abs();
            self.stats.max_slip_angle = self.stats.max_slip_angle.max(slip_angle.to_degrees());
        }
        let b = &mut phys.world.bodies[self.body];
        b.reset_forces(true);
        b.reset_torques(true);
        b.add_force(force, true);
        b.add_torque(torque, true);
    }

    fn suspension(&mut self, phys: &Physics, ground: &dyn Ground, xf: &Pose3, up: Vec3, dt: f64, level: f64, apply: &mut impl FnMut(Vec3, Vec3)) {
        let travel = self.spec.travel;
        let reach = travel + OVER_BUMP;
        let shape = Cylinder::new(0.1, self.spec.wheel_radius as f32);
        let filter = QueryFilter::default()
            .exclude_rigid_body(self.body)
            .groups(InteractionGroups::new(Group::ALL, GROUP_WORLD, InteractionTestMode::And));
        let qp = phys.world.query_pipeline_with_filter(filter);
        let lay = Quat::from_axis_angle(Vec3::Z, (PI / 2.0) as f32);
        for w in self.wheels.iter_mut() {
            let top = xf.transform_point(w.anchor + Vec3::Y * reach as f32);
            let rot = Quat::from_axis_angle(up, w.steer as f32) * xf.rotation * lay;
            let pose = Pose3::from_parts(top, rot);
            let motion = -up * reach as f32;
            w.last_compression = w.compression;
            let opts = ShapeCastOptions { max_time_of_impact: 1.0, target_distance: 0.0, stop_at_penetration: true, compute_impact_geometry_on_penetration: true };
            let found = qp.cast_shape(&pose, motion, &shape, opts).map(|(h, hit)| (h, hit.time_of_impact, hit.witness1, hit.normal1));
            let Some((handle, toi, point, n)) = found else {
                w.contact = false;
                w.compression = 0.0;
                w.load = 0.0;
                continue;
            };
            w.contact = true;
            let t = toi.max(0.0) as f64;
            w.compression = (reach * (1.0 - t)).clamp(0.0, reach);
            w.point = point;
            w.normal = if n.dot(up) > 0.5 { n } else { up };
            let tag = phys.world.colliders[handle].user_data;
            w.surface = if level > w.point.y as f64 + 0.08 {
                Surface::Water
            } else if tag == ROAD {
                let (s, hint) = ground.road_surface(w.point, w.road_hint);
                w.road_hint = hint;
                s
            } else {
                Surface::from_u8(tag as u8)
            };
        }
        for axle in 0..2 {
            let (l, r) = (axle * 2, axle * 2 + 1);
            let roll = (self.wheels[l].compression - self.wheels[r].compression) * self.spec.arb[axle];
            for (k, sign) in [(l, 1.0), (r, -1.0)] {
                let w = &mut self.wheels[k];
                if !w.contact {
                    continue;
                }
                let rate = ((w.compression - w.last_compression) / dt).clamp(-4.0, 4.0);
                let damper = if rate > 0.0 { self.spec.bump[axle] } else { self.spec.rebound[axle] } * rate;
                let mut force = self.spec.spring[axle] * w.compression + damper + roll * sign;
                let stop = travel * 0.88;
                if w.compression > stop {
                    force += (w.compression - stop) * self.spec.spring[axle] * 14.0;
                }
                w.load = force.clamp(0.0, 24000.0);
                apply(up * w.load as f32, w.point);
            }
        }
    }

    fn drivetrain(&mut self, h: f64, surfaces: &Surfaces) {
        for w in self.wheels.iter_mut() {
            w.omega += -w.fx * w.radius * h / w.inertia;
        }
        let spec = &self.spec;
        let rpm = self.engine_omega * RPM;
        let cut = self.shift_timer > 0.0 || rpm > spec.limit_rpm;
        let mut t = self.throttle;
        if self.gear < 0 && !self.manual {
            t = self.brake;
        }
        let idle_assist = ((spec.idle_rpm - rpm) / 250.0).clamp(0.0, 0.35);
        t = t.max(idle_assist);
        if cut {
            t = 0.0;
        }
        self.engine_torque = torque_curve(&spec.torque, rpm) * t - (spec.friction[0] + spec.friction[1] * rpm) * (1.0 - t);
        self.engine_omega += self.engine_torque * h / spec.engine_inertia;
        self.engine_omega = self.engine_omega.max(300.0 / RPM);

        let centre_open = self.handbrake > 0.1;
        let shares: [f64; 4] = if centre_open {
            [0.5, 0.5, 0.0, 0.0]
        } else {
            [spec.drive[0] * 0.5, spec.drive[0] * 0.5, spec.drive[1] * 0.5, spec.drive[1] * 0.5]
        };
        let mut axle_torque = [0.0f64; 2];
        if self.shift_timer <= 0.0 && !self.hold {
            let mut g = if self.gear < 0 { spec.gears[0] * -1.0 } else { spec.gears[self.gear as usize] };
            g *= spec.final_drive;
            let mut w_t = 0.0;
            let mut k = 0.0;
            for i in 0..4 {
                w_t += shares[i] * self.wheels[i].omega;
                k += shares[i] * shares[i] / self.wheels[i].inertia;
            }
            k *= g * g;
            let slip = self.engine_omega - g * w_t;
            let rpm = self.engine_omega * RPM;
            let mut engage = smoothstep(spec.idle_rpm + 150.0, 3600.0, rpm).max(smoothstep(spec.idle_rpm + 300.0, 2600.0, (g * w_t).abs() * RPM));
            if slip.abs() < 30.0 && rpm > spec.idle_rpm + 600.0 {
                engage = 1.0;
            }
            let cap = spec.clutch * engage;
            let tau = (slip / (h * (1.0 / spec.engine_inertia + k))).clamp(-cap, cap);
            self.engine_omega -= tau * h / spec.engine_inertia;
            for i in 0..4 {
                let wt = shares[i] * tau * g;
                self.wheels[i].omega += wt * h / self.wheels[i].inertia;
                axle_torque[i / 2] += wt.abs();
            }
        }
        if !centre_open {
            let front = (self.wheels[0].omega + self.wheels[1].omega) * 0.5;
            let rear = (self.wheels[2].omega + self.wheels[3].omega) * 0.5;
            let i_w = self.wheels[0].inertia;
            let tau_c = ((front - rear) * i_w / h).clamp(-spec.centre_lock, spec.centre_lock);
            for i in 0..4 {
                self.wheels[i].omega += if i < 2 { -0.5 } else { 0.5 } * tau_c * h / self.wheels[i].inertia;
            }
        }
        for axle in 0..2 {
            let cap_d = spec.diff_preload[axle] + spec.diff_ramp[axle] * axle_torque[axle];
            let (li, ri) = (self.wheels[axle * 2].inertia, self.wheels[axle * 2 + 1].inertia);
            let tau_d = ((self.wheels[axle * 2].omega - self.wheels[axle * 2 + 1].omega) / (h * (1.0 / li + 1.0 / ri))).clamp(-cap_d, cap_d);
            self.wheels[axle * 2].omega -= tau_d * h / li;
            self.wheels[axle * 2 + 1].omega += tau_d * h / ri;
        }
        let mut foot = if self.gear > 0 || self.manual { self.brake } else { self.throttle };
        if self.hold {
            foot = 1.0;
        }
        for w in self.wheels.iter_mut() {
            let mut t_b = foot * spec.brake[w.axle];
            if w.axle == 1 {
                t_b += self.handbrake * spec.handbrake;
            }
            if w.contact {
                t_b += surfaces.get(w.surface).rolling * w.load * w.radius;
            }
            let stop = t_b * h / w.inertia;
            w.omega = if w.omega.abs() <= stop { 0.0 } else { w.omega - w.omega.signum() * stop };
        }
    }

    fn steering(&mut self, dt: f64, lin: Vec3, right_axis: Vec3, fwd: Vec3) {
        let mut lock = self.spec.max_steer();
        let ground_speed = lin.length() as f64;
        if self.steer_assist && ground_speed > 6.0 {
            let beta = (lin.dot(right_axis) as f64).atan2((lin.dot(fwd) as f64).abs()).abs();
            let useful = beta + 9.0f64.to_radians();
            lock += (lock.min(useful) - lock) * ((ground_speed - 6.0) / 22.0).clamp(0.0, 1.0);
        }
        let target = -self.steer_input * lock;
        let current = self.wheels[0].steer;
        let rate = if target.abs() > current.abs() { 3.2 } else { 4.5 };
        let next = move_toward(current, target, rate * dt);
        for w in self.wheels.iter_mut() {
            w.steer = if w.axle == 0 { next } else { 0.0 };
        }
    }

    fn gearbox(&mut self, dt: f64) {
        if self.hold {
            self.gear = 1;
            self.shift_timer = 0.0;
            self.shift_request = 0;
            return;
        }
        if self.shift_timer > 0.0 {
            self.shift_timer -= dt;
            if self.shift_timer <= 0.0 {
                self.gear = self.shift_target;
            }
            return;
        }
        let top = self.spec.gears.len() as i32 - 1;
        if self.shift_request != 0 {
            let mut want = self.gear + self.shift_request;
            self.shift_request = 0;
            if self.gear == 1 && want == 0 {
                want = if self.speed < 2.5 { -1 } else { 1 };
            } else if self.gear == -1 && want == 0 {
                want = 1;
            }
            want = want.clamp(-1, top);
            if want != self.gear && (want < 0 || (want < self.gear && self.rpm_in(want) < self.spec.limit_rpm + 200.0) || want > self.gear) {
                self.shift(want);
            }
            return;
        }
        if self.manual {
            return;
        }
        let rpm = self.rpm();
        if self.gear > 0 {
            if self.brake > 0.5 && self.throttle < 0.1 && self.speed < 0.6 {
                self.reverse_hold += dt;
                if self.reverse_hold > 0.35 {
                    self.reverse_hold = 0.0;
                    self.shift(-1);
                    return;
                }
            } else {
                self.reverse_hold = 0.0;
            }
            let slipping = self.wheels.iter().any(|w| w.slide > 0.4);
            if self.gear < top && rpm > self.spec.upshift_rpm && self.throttle > 0.2 && self.on_ground >= 2 && !(slipping && self.speed < 12.0) {
                self.shift(self.gear + 1);
            } else if self.gear > 1 {
                let down = self.spec.downshift_rpm + 1400.0 * self.brake - 900.0 * (1.0 - self.throttle);
                if rpm < down && self.rpm_in(self.gear - 1) < self.spec.upshift_rpm - 500.0 {
                    self.shift(self.gear - 1);
                }
            }
        } else if self.gear < 0 && self.throttle > 0.4 && self.speed > -1.0 {
            self.shift(1);
        }
    }

    fn rpm_in(&self, g: i32) -> f64 {
        let ratio = if g < 0 { self.spec.gears[0] } else { self.spec.gears[g as usize] } * self.spec.final_drive;
        let mut w_t: f64 = self.wheels.iter().map(|w| w.omega.abs() * 0.25).sum();
        w_t = w_t.max(self.speed.abs() / self.spec.wheel_radius);
        w_t * ratio * RPM
    }

    fn shift(&mut self, to: i32) {
        self.shift_target = to;
        self.shift_timer = self.spec.shift_time;
        self.stats.shifts += 1;
    }
}

/// Slip to force: the normalised slip vector picks the direction, its
/// length the point on the curve.
fn tyre(w: &Wheel, surfaces: &Surfaces, grip_scale: f64) -> (f64, f64) {
    if !w.contact || w.load <= 0.0 {
        return (0.0, 0.0);
    }
    let surf = surfaces.get(w.surface);
    let kn = w.kappa / surf.kappa_peak;
    let an = w.tan_alpha / surf.alpha_peak;
    let s = (kn * kn + an * an).sqrt();
    if s < 1e-6 {
        return (0.0, 0.0);
    }
    let mu = surf.mu * grip_scale * (1.0 - 0.07 * (w.load / 3000.0 - 1.0)).clamp(0.75, 1.1);
    let f = mu * w.load * curve(s, surf.c);
    (f * kn / s * 1.04, -f * an / s)
}

fn torque_curve(pts: &[[f64; 2]], r: f64) -> f64 {
    if r <= pts[0][0] {
        return pts[0][1];
    }
    for i in 1..pts.len() {
        if r <= pts[i][0] {
            let (a, b) = (pts[i - 1], pts[i]);
            return a[1] + (b[1] - a[1]) * (r - a[0]) / (b[0] - a[0]);
        }
    }
    0.0
}

