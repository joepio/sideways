//! Rounds of stages with bots, as main.gd runs them for `--sim`: countdown,
//! racing, recovery when lost or stuck, finish, results, the next stage.
//! Implements `kern::Sim`, so every engine tool works on it.

use crate::ai::RallyAi;
use crate::builder;
use crate::car::{Car, Ground};
use crate::physics::{HZ, Physics};
use crate::spec::{Cars, GRID};
use crate::stage::{RUNOUT, Stage};
use crate::surfaces::{Surface, Surfaces};
use gdcompat::Pcg;
use gdcompat::math::v3;
use kern::{Digest, Sim, Timings};
use rapier3d::glamx::{Pose3, Quat, Vec3};
use serde::Serialize;
use serde_json::{Value, json};

pub const COUNTDOWN: f64 = 3.0;
pub const RESULTS_SECONDS: f64 = 9.0;
pub const FINISH_GRACE: f64 = 40.0;
pub const RECOVER_PENALTY: f64 = 5.0;
pub const GHOST_SECONDS: f64 = 2.0;
pub const WEATHERS: [(&str, f64); 4] = [("clear", 0.0), ("overcast", 0.25), ("mist", 0.45), ("wet", 1.0)];
const NAMES: [&str; 8] = ["Red", "Blue", "Yellow", "Green", "Purple", "Orange", "Pink", "Grey"];

#[derive(Clone, Debug)]
pub struct Settings {
    pub stage_km: f64,
    pub rivals: usize,
    pub contact: bool,
    pub weather: Option<String>,
    pub manual: bool,
    pub bots: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { stage_km: 3.0, rivals: 1, contact: true, weather: None, manual: false, bots: 1 }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Player {
    pub name: String,
    pub rival: bool,
    pub car: Car,
    pub ai: RallyAi,
    pub time: f64,
    pub finished: bool,
    pub penalty: f64,
    pub hint: i64,
    pub along: f64,
    pub ghost: f64,
    pub off_road: f64,
    pub off_track: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Stats {
    pub stages: u32,
    pub finishes: u32,
    pub shifts: u32,
    pub recoveries: u32,
    pub airtime: f64,
    pub slides: f64,
}

pub struct Race {
    pub settings: Settings,
    pub rng: Pcg,
    pub cars: Cars,
    pub stage: Stage,
    pub phys: Physics,
    pub surfaces: Surfaces,
    pub weather: &'static str,
    pub players: Vec<Player>,
    pub phase: &'static str,
    pub clock: f64,
    pub results: f64,
    pub first_finish: f64,
    pub round: u32,
    pub frame: u64,
    pub stats: Stats,
    /// One line per event when tracing (finish, recover, new stage).
    pub events: Vec<String>,
}

struct StageGround<'a>(&'a Stage);

impl Ground for StageGround<'_> {
    fn road_surface(&self, p: Vec3, hint: i64) -> (Surface, i64) {
        self.0.surface_near(v3(p.x, p.y, p.z), hint)
    }
    fn water_level(&self, x: f64, z: f64) -> f64 {
        if self.0.rivers.is_empty() { f64::NEG_INFINITY } else { self.0.water_level(x, z) }
    }
}

/// Colliders for a whole stage: terrain chunks (built on all cores), the
/// road ribbon, tree trunks and barriers.
pub fn build_colliders(stage: &Stage) -> (Physics, usize, usize) {
    let mut phys = Physics::new();
    let cells = builder::chunk_cells(stage);
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(16);
    let mut chunks: Vec<Option<builder::Chunk>> = (0..cells.len()).map(|_| None).collect();
    std::thread::scope(|s| {
        for (part, slot) in chunks.chunks_mut(cells.len().div_ceil(threads)).enumerate() {
            let cells = &cells;
            let base = part * cells.len().div_ceil(threads);
            s.spawn(move || {
                for (k, out) in slot.iter_mut().enumerate() {
                    *out = Some(builder::terrain_chunk(stage, cells[base + k]));
                }
            });
        }
    });
    let mut trees = 0;
    for c in chunks.iter().flatten() {
        phys.add_chunk(c);
        for t in &c.trees {
            phys.add_trunk(t);
        }
        trees += c.trees.len();
    }
    phys.add_road(&builder::road(stage));
    for b in builder::barriers(stage) {
        phys.add_block(&b);
    }
    (phys, cells.len(), trees)
}

impl Race {
    pub fn new(seed: u64, settings: Settings, cars: Cars) -> Race {
        let mut rng = Pcg::new(seed);
        let empty = Stage::generate(&mut Pcg::new(0), 10.0);
        let mut race = Race {
            settings,
            rng: Pcg::new(0),
            cars,
            stage: empty,
            phys: Physics::new(),
            surfaces: Surfaces::default(),
            weather: "clear",
            players: vec![],
            phase: "countdown",
            clock: 0.0,
            results: 0.0,
            first_finish: -1.0,
            round: 0,
            frame: 0,
            stats: Stats::default(),
            events: vec![],
        };
        std::mem::swap(&mut race.rng, &mut rng);
        race.new_stage(&mut Timings::default());
        race
    }

    fn event(&mut self, s: String) {
        self.events.push(format!("[{:>6}] {s}", self.frame));
    }

    pub fn new_stage(&mut self, timings: &mut Timings) {
        self.round += 1;
        self.stats.stages += 1;
        let (w, wet) = WEATHERS[(self.rng.next_u32() % 4) as usize];
        self.weather = match &self.settings.weather {
            Some(f) => WEATHERS.iter().find(|x| x.0 == f).map(|x| x.0).unwrap_or(w),
            None => w,
        };
        let wet = WEATHERS.iter().find(|x| x.0 == self.weather).map(|x| x.1).unwrap_or(wet);
        self.surfaces = Surfaces::with_wetness(&Surfaces::default(), wet);
        let km = self.settings.stage_km;
        let rng = &mut self.rng;
        self.stage = timings.span("layout", || Stage::generate(rng, km * 1000.0 + RUNOUT));
        let stage = &self.stage;
        let (phys, chunks, trees) = timings.span("colliders", || build_colliders(stage));
        self.phys = phys;
        self.event(format!("stage {}: {:.0} m, {} chunks, {} trees, weather {}", self.round, self.stage.length, chunks, trees, self.weather));
        // Bots with views, then the rivals.
        let mut roster: Vec<(String, bool)> = (0..self.settings.bots).map(|i| (NAMES[i % 8].to_string(), false)).collect();
        let rivals = if self.settings.rivals == 1 && self.settings.bots >= 2 { 0 } else { self.settings.rivals };
        for r in 0..rivals {
            roster.push((format!("AI {}", r + 1), true));
        }
        self.players.clear();
        for (i, (name, rival)) in roster.into_iter().enumerate() {
            let spec = self.cars.get(GRID[i % GRID.len()]).expect("car spec");
            let body = self.phys.add_car(&spec, Pose3::IDENTITY, self.settings.contact);
            let mut car = Car::new(spec, body);
            car.manual = self.settings.manual;
            let pace = if rival { self.rng.randf_range(0.86, 0.97) } else { 0.95 };
            let _wobble = self.rng.randf_global(); // RallyAI draws it; keeps the stream in step
            let ai = RallyAi::new(&self.stage, &self.surfaces, pace);
            self.players.push(Player { name, rival, car, ai, time: 0.0, finished: false, penalty: 0.0, hint: -1, along: 0.0, ghost: 0.0, off_road: 0.0, off_track: 0.0 });
            self.place(i, 0.0, i);
        }
        self.phase = "countdown";
        self.clock = -COUNTDOWN;
        self.first_finish = -1.0;
        self.results = 0.0;
    }

    fn place(&mut self, i: usize, along: f64, slot: usize) {
        let mut a = along.clamp(4.0, self.stage.finish - 12.0);
        let mut offset = 0.0;
        if self.settings.contact {
            a -= (slot / 2) as f64 * 8.0;
            offset = if slot % 2 == 0 { -1.3 } else { 1.3 };
        }
        let mut pos = self.stage.point_at(a);
        let dir = self.stage.dir_at(a);
        let right = v3(-dir.z, 0.0, dir.x);
        pos += right * offset as f32;
        pos.y = (self.stage.height(pos.x as f64, pos.z as f64) + 0.36) as f32;
        let rot = Quat::from_rotation_arc(Vec3::NEG_Z, Vec3::new(dir.x, dir.y, dir.z).normalize());
        let pose = Pose3::from_parts(Vec3::new(pos.x, pos.y, pos.z), rot);
        let p = &mut self.players[i];
        p.car.teleport(&mut self.phys, pose);
        p.hint = -1;
        p.along = a;
    }

    fn dry_along(&self, along: f64) -> f64 {
        let mut a = along;
        while a > 4.0 {
            let wet = [-10.0, -5.0, 0.0, 5.0, 10.0].iter().any(|d| {
                let q = self.stage.point_at((a + d).clamp(0.0, self.stage.length));
                let (x, z) = (q.x as f64, q.z as f64);
                self.stage.water_level(x, z) > self.stage.height(x, z) - 0.3
            });
            if !wet {
                return a;
            }
            a -= 4.0;
        }
        a
    }

    fn near_other(&self, i: usize, r: f32) -> bool {
        let me = self.players[i].car.pose(&self.phys).translation;
        self.players.iter().enumerate().any(|(j, o)| j != i && o.car.pose(&self.phys).translation.distance(me) < r)
    }

    fn recover(&mut self, i: usize) {
        self.stats.recoveries += 1;
        let along = self.players[i].along;
        {
            let p = &mut self.players[i];
            p.off_track = 0.0;
            p.off_road = 0.0;
            p.penalty += RECOVER_PENALTY;
        }
        let a = self.dry_along(along - 6.0);
        self.place(i, a, 0);
        if self.settings.contact {
            self.players[i].ghost = GHOST_SECONDS;
            self.phys.set_car_contact(self.players[i].car.body, false);
        }
        self.players[i].ai.stuck = 0.0;
        self.players[i].ai.hint = -1;
        let name = self.players[i].name.clone();
        self.event(format!("recover {name}"));
    }

    fn drive(&mut self, i: usize, dt: f64) {
        let pos = self.players[i].car.pose(&self.phys).translation;
        let loc = self.stage.locate(v3(pos.x, pos.y, pos.z), self.players[i].hint);
        if loc.index >= 0 {
            self.players[i].hint = loc.index;
            self.players[i].along = loc.along;
        }
        let racing = self.phase != "countdown";
        let finished = self.players[i].finished;
        self.players[i].car.hold = !racing || finished;
        if self.players[i].ghost > 0.0 {
            self.players[i].ghost -= dt;
            if self.players[i].ghost <= 0.0 && self.near_other(i, 6.0) {
                self.players[i].ghost = 0.3;
            } else if self.players[i].ghost <= 0.0 {
                self.phys.set_car_contact(self.players[i].car.body, true);
            }
        }
        let p = &mut self.players[i];
        if !racing {
            p.car.throttle = if self.clock > -0.8 { 0.6 } else { 0.0 };
            return;
        }
        if finished {
            p.car.throttle = 0.0;
            p.car.brake = 1.0;
            p.car.handbrake = 0.0;
            p.car.steer_input = 0.0;
            return;
        }
        p.ai.drive(&mut p.car, &self.phys, &self.stage, dt);
        self.stats.airtime = self.stats.airtime.max(p.car.stats.air_time);
        for w in &p.car.wheels {
            if w.slide > 0.3 {
                self.stats.slides += dt * 0.25;
            }
        }
        let (lin, up_y) = {
            let b = &self.phys.world.bodies[p.car.body];
            (b.linvel(), (b.position().rotation * Vec3::Y).y)
        };
        let width = self.stage.width_at(p.along);
        let lost = loc.index < 0 || loc.offset.abs() > width + 22.0;
        let upside = up_y < 0.2;
        let stuck = lin.length() < 1.0 && (p.car.throttle > 0.5 || p.car.brake > 0.5);
        let off_track = lost || upside || stuck || loc.offset.abs() > width + 2.5;
        p.off_track = if off_track { p.off_track + dt } else { 0.0 };
        p.off_road = if lost || upside || stuck || p.ai.stuck > 3.0 { p.off_road + dt } else { 0.0 };
        let limit = if upside || lost { 2.5 } else { 5.0 };
        if p.off_road > limit {
            let line = format!("lost {} at {:.0} m: lost {lost} upside {upside} stuck {stuck} offset {:.1}", p.name, p.along, loc.offset);
            self.event(line);
            self.recover(i);
        }
        let p = &mut self.players[i];
        if p.along >= self.stage.finish {
            p.finished = true;
            p.time = self.clock + p.penalty;
            self.stats.finishes += 1;
            if self.first_finish < 0.0 {
                self.first_finish = self.clock;
            }
            let line = format!("finish {} {:.2}", p.name, p.time);
            self.event(line);
        }
    }

    fn end_stage(&mut self) {
        self.phase = "results";
        self.results = RESULTS_SECONDS;
        for p in &mut self.players {
            if !p.finished {
                p.time = f64::INFINITY;
            }
            self.stats.shifts += p.car.stats.shifts;
        }
        let winner = self.players.iter().min_by(|a, b| a.time.partial_cmp(&b.time).unwrap()).map(|p| p.name.clone()).unwrap_or_default();
        self.event(format!("stage {} won by {winner}", self.round));
    }

    /// The summary main.gd prints at the end of `--sim`.
    pub fn summary(&self) -> (Stats, String) {
        let mut stats = self.stats.clone();
        stats.shifts += self.players.iter().map(|p| p.car.stats.shifts).sum::<u32>();
        let state: Vec<String> = self
            .players
            .iter()
            .map(|p| {
                let t = p.car.pose(&self.phys).translation;
                format!("{:.3},{:.3},{:.3},{:.2}", t.x, t.y, t.z, p.along)
            })
            .collect();
        let mut d = Digest::default();
        d.bytes(state.join(";").as_bytes());
        (stats, d.hex16())
    }
}

impl Sim for Race {
    fn step(&mut self, timings: &mut Timings) {
        let dt = 1.0 / HZ;
        self.frame += 1;
        self.clock += dt;
        if self.phase == "results" {
            self.results -= dt;
            if self.results <= 0.0 {
                self.new_stage(timings);
                return;
            }
        }
        timings.span("drive", || {
            for i in 0..self.players.len() {
                self.drive(i, dt);
            }
        });
        if self.phase == "countdown" && self.clock >= 0.0 {
            self.phase = "racing";
        }
        if self.phase == "racing" {
            let all_done = self.players.iter().all(|p| p.finished);
            if all_done || (self.first_finish >= 0.0 && self.clock - self.first_finish > FINISH_GRACE) {
                self.end_stage();
            }
        }
        timings.span("car forces", || {
            let ground = StageGround(&self.stage);
            for p in &mut self.players {
                p.car.integrate(&mut self.phys, &ground, &self.surfaces, dt);
            }
        });
        timings.span("rapier step", || self.phys.step());
    }

    fn tick(&self) -> u64 {
        self.frame
    }

    fn digest(&self, d: &mut Digest) {
        d.u64(self.frame);
        for p in &self.players {
            let b = &self.phys.world.bodies[p.car.body];
            let t = b.position().translation;
            let r = b.position().rotation;
            let (l, a) = (b.linvel(), b.angvel());
            for x in [t.x, t.y, t.z, r.x, r.y, r.z, r.w, l.x, l.y, l.z, a.x, a.y, a.z] {
                d.f32(x);
            }
            d.f64(p.car.engine_omega);
            for w in &p.car.wheels {
                d.f64(w.omega);
                d.f64(w.kappa);
                d.f64(w.tan_alpha);
            }
        }
    }

    fn query(&self, path: &str) -> Option<Value> {
        let parts: Vec<&str> = path.split('.').collect();
        let root = match parts[0] {
            "players" | "p" => {
                let list: Vec<Value> = self
                    .players
                    .iter()
                    .map(|p| {
                        let b = &self.phys.world.bodies[p.car.body];
                        let mut v = serde_json::to_value(p).unwrap();
                        let t = b.position().translation;
                        let l = b.linvel();
                        v["pos"] = json!([t.x, t.y, t.z]);
                        v["vel"] = json!([l.x, l.y, l.z]);
                        v["kmh"] = json!(l.length() * 3.6);
                        v["rpm"] = json!(p.car.rpm());
                        v
                    })
                    .collect();
                Value::Array(list)
            }
            "stats" => serde_json::to_value(&self.stats).ok()?,
            "phase" => return Some(json!(self.phase)),
            "clock" => return Some(json!(self.clock)),
            "weather" => return Some(json!(self.weather)),
            "round" => return Some(json!(self.round)),
            _ => return None,
        };
        kern::walk(&root, &parts[1..]).cloned()
    }
}
