//! The stage layout, ported from src/stage.gd. Same seed, same road: the
//! arithmetic follows Godot's float widths (f64 scalars, f32 vectors and
//! packed arrays) so the oracle can compare it number for number.

use crate::surfaces::Surface;
use gdcompat::math::{V2, V3, lerp, signf, smoothstep, v2, v3};
use gdcompat::{Noise, Pcg, Var, hash};
use std::collections::HashMap;

pub const STEP: f64 = 2.0;
pub const CELL: f64 = 32.0;
pub const REACH: f64 = 70.0;
pub const CHUNK: f64 = 64.0;
pub const GRID: f64 = 2.0;
pub const CORRIDOR: f64 = 230.0;
pub const RUNOUT: f64 = 140.0;
pub const RIVER_STEP: f64 = 4.0;

#[derive(Clone, Debug)]
pub struct River {
    pub pts: Vec<V2>,
    pub levels: Vec<f32>,
    pub wet: Vec<u8>,
    pub half: f64,
    pub depth: f64,
    pub cross: usize,
    pub ford: bool,
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct Note {
    pub at: f64,
    pub kind: &'static str,
    pub grade: i32,
    pub end: f64,
}

/// Where a point is relative to the centre line.
#[derive(Clone, Copy, Debug)]
pub struct Located {
    pub index: i64,
    pub along: f64,
    pub offset: f64,
    pub height: f64,
    pub right: V3,
}

impl Located {
    const NONE: Located = Located { index: -1, along: 0.0, offset: f64::INFINITY, height: 0.0, right: V3::ZERO };
}

type Cell = (i32, i32);

fn cell_of(x: f64, z: f64) -> Cell {
    ((x / CELL).floor() as i32, (z / CELL).floor() as i32)
}

pub struct Stage {
    pub points: Vec<V3>,
    pub dirs: Vec<V3>,
    pub widths: Vec<f32>,
    pub road_surfaces: Vec<u8>,
    pub curvature: Vec<f32>,
    pub length: f64,
    pub finish: f64,
    pub ledges: Vec<f32>,
    pub ledge_wall: Vec<f32>,
    pub ledge_drop: Vec<f32>,
    pub rivers: Vec<River>,
    pub notes: Vec<Note>,
    pub noise_seed: i32,
    pub detail_seed: i32,
    noise: Noise,
    pub detail: Noise,
    hash: HashMap<Cell, Vec<i32>>,
    locate_candidates: HashMap<Cell, Vec<i32>>,
    river_candidates: HashMap<Cell, Vec<(usize, usize)>>,
}

impl Stage {
    /// `Stage.generate(target_length)`, drawing from the global RNG.
    pub fn generate(rng: &mut Pcg, target_length: f64) -> Stage {
        // FastNoiseLite stores the seed as a 32-bit int.
        let noise_seed = rng.next_u32() as i32;
        let detail_seed = rng.next_u32() as i32;
        let mut s = Stage {
            points: vec![],
            dirs: vec![],
            widths: vec![],
            road_surfaces: vec![],
            curvature: vec![],
            length: 0.0,
            finish: 0.0,
            ledges: vec![],
            ledge_wall: vec![],
            ledge_drop: vec![],
            rivers: vec![],
            notes: vec![],
            noise_seed,
            detail_seed,
            noise: Noise::new(noise_seed, 1.0 / 420.0, 3),
            detail: Noise::new(detail_seed, 1.0 / 70.0, 2),
            hash: HashMap::new(),
            locate_candidates: HashMap::new(),
            river_candidates: HashMap::new(),
        };
        s.layout(rng, target_length);
        s.profile(rng);
        s.make_ledges(rng);
        s.make_rivers(rng);
        s.index();
        s.pace_notes();
        s.make_road_surfaces();
        s
    }

    fn make_road_surfaces(&mut self) {
        let n = self.points.len();
        self.road_surfaces = vec![Surface::Gravel as u8; n];
        let mut rng = Pcg::new(hash(&Var::Array(&[
            Var::Int(self.noise_seed as i64),
            Var::Int(self.detail_seed as i64),
            Var::Str("road surfaces"),
        ])) as u64);
        let mut block_start = 0.0f64;
        while self.finish - block_start >= 600.0 {
            let span = (self.finish - block_start).min(1200.0);
            let kinds = [Surface::Dirt, Surface::Mud, Surface::Asphalt];
            let fractions = [0.20, 0.48, 0.75];
            let lengths = [0.06, 0.08, 0.06];
            for j in 0..3 {
                let start = block_start + span * (fractions[j] + rng.randf_range_f32(-0.015, 0.015) as f64);
                let metres = (span * lengths[j] * rng.randf_range_f32(0.9, 1.1) as f64).max(40.0);
                let first = ((start / STEP).floor() as i64).clamp(0, n as i64 - 1) as usize;
                let end = (first + ((metres / STEP).floor() as usize).max(20)).min(n);
                for row in first..end {
                    self.road_surfaces[row] = kinds[j] as u8;
                }
            }
            block_start += span;
        }
    }

    pub fn road_surface_at(&self, along: f64) -> Surface {
        if self.road_surfaces.is_empty() {
            return Surface::Gravel;
        }
        let i = ((along / STEP).floor() as i64).clamp(0, self.road_surfaces.len() as i64 - 1);
        Surface::from_u8(self.road_surfaces[i as usize])
    }

    fn layout(&mut self, rng: &mut Pcg, target_length: f64) {
        self.points = vec![V3::ZERO];
        let mut remaining = ((target_length / STEP).ceil() as i64).max(0);
        let mut p = V2::default();
        let mut heading = 0.0f64;
        let mut straight_steps = remaining.min((120.0f64 / STEP).ceil() as i64);
        let mut fast_corners = 0;
        let step = STEP as f32;
        while remaining > 0 {
            for _ in 0..straight_steps.min(remaining) {
                p += v2(heading.sin() as f32, -heading.cos() as f32) * step;
                self.points.push(v3(p.x, 0.0, p.y));
                remaining -= 1;
            }
            if remaining == 0 {
                break;
            }
            let mut grade = pick_grade(rng);
            if fast_corners >= 2 {
                grade = grade.min(2);
            }
            fast_corners = if grade > 2 { fast_corners + 1 } else { 0 };
            let radius = [14.0, 24.0, 38.0, 60.0, 95.0, 150.0, 240.0][grade];
            let mut turn_sign = -signf(heading);
            if turn_sign == 0.0 {
                turn_sign = if rng.randf_global() < 0.5 { 1.0 } else { -1.0 };
            }
            let target_heading = turn_sign * rng.randf_range(20.0, 50.0).to_radians_godot();
            let delta = target_heading - heading;
            let turn_steps = ((1.5 * radius * delta.abs() / STEP).ceil() as i64).max(1);
            for st in 0..turn_steps.min(remaining) {
                let t = (st as f64 + 0.5) / turn_steps as f64;
                let eased = t * t * (3.0 - 2.0 * t);
                let direction = heading + delta * eased;
                p += v2(direction.sin() as f32, -direction.cos() as f32) * step;
                self.points.push(v3(p.x, 0.0, p.y));
                remaining -= 1;
            }
            heading = target_heading;
            if remaining > 0 {
                straight_steps = ((rng.randf_range(15.0, 155.0) / STEP).round() as i64).clamp(8, 77);
            }
        }
    }

    fn profile(&mut self, rng: &mut Pcg) {
        let n = self.points.len();
        let raw: Vec<f32> = self.points.iter().map(|p| self.ground(p.x as f64, p.z as f64) as f32).collect();
        let mut smooth = raw;
        for _ in 0..3 {
            let mut out = smooth.clone();
            let r = 15usize;
            for i in 0..n {
                let mut acc = 0.0f64;
                let mut cnt = 0;
                for j in i.saturating_sub(r)..(i + r + 1).min(n) {
                    acc += smooth[j] as f64;
                    cnt += 1;
                }
                out[i] = (acc / cnt as f64) as f32;
            }
            smooth = out;
        }
        let max_d = 0.11 * STEP;
        for i in 1..n {
            let prev = smooth[i - 1] as f64;
            smooth[i] = (smooth[i] as f64).clamp(prev - max_d, prev + max_d) as f32;
        }
        for i in (0..n.saturating_sub(1)).rev() {
            let next = smooth[i + 1] as f64;
            smooth[i] = (smooth[i] as f64).clamp(next - max_d, next + max_d) as f32;
        }
        self.dirs = (0..n)
            .map(|i| (self.points[(i + 1).min(n - 1)] - self.points[i.saturating_sub(1)]).normalized())
            .collect();
        self.curvature = (0..n)
            .map(|i| {
                let lo = i.saturating_sub(3);
                let hi = (i + 3).min(n - 1);
                let a = self.dirs[lo];
                let b = self.dirs[hi];
                let turn = (a.cross(b).y as f64).atan2(a.dot(b) as f64);
                (turn / (STEP * (hi - lo) as f64)) as f32
            })
            .collect();
        let mut i = 40usize;
        while n > 40 && i < n - 40 {
            let straight = (i - 15..i + 15).all(|j| (self.curvature[j] as f64).abs() <= 1.0 / 400.0);
            if straight && (rng.randf_global() as f64) < 0.35 {
                let height = rng.randf_range(0.6, 1.6);
                let half = rng.randf_range(5.0, 9.0);
                for j in i - 20..i + 20 {
                    let x = (j as f64 - i as f64) / half;
                    smooth[j] = (smooth[j] as f64 + height * (-x * x).exp()) as f32;
                }
                i += 60;
            } else {
                i += 5;
            }
        }
        self.widths = vec![0.0; n];
        for j in 0..n {
            self.points[j].y = smooth[j];
            self.widths[j] = (3.4 + 0.5 * self.detail.get_1d((j as f64 * 0.7) as f32) as f64) as f32;
        }
        self.length = (n - 1) as f64 * STEP;
        self.finish = self.length - RUNOUT;
    }

    fn make_ledges(&mut self, rng: &mut Pcg) {
        let n = self.points.len();
        self.ledges = vec![0.0; n];
        self.ledge_wall = vec![0.0; n];
        self.ledge_drop = vec![0.0; n];
        let mut i = 90usize;
        while n > 80 && i < n - 80 {
            if rng.randf_global() as f64 > 0.007 {
                i += 1;
                continue;
            }
            let len = rng.randi_range(60, 150) as usize;
            let end = (i + len).min(n - 60);
            let mid = (i + end) / 2;
            let right = v3(-self.dirs[mid].z, 0.0, self.dirs[mid].x);
            let p = self.points[mid];
            let (px, pz, rx, rz) = (p.x as f64, p.z as f64, right.x as f64, right.z as f64);
            let rise = self.ground(px + rx * 40.0, pz + rz * 40.0) - self.ground(px - rx * 40.0, pz - rz * 40.0);
            let side = if rise >= 0.0 { 1.0 } else { -1.0 };
            let wall = rng.randf_range(9.0, 22.0);
            let drop = rng.randf_range(14.0, 34.0);
            for j in i..=end {
                let ease = smoothstep(0.0, 15.0, (j - i) as f64).min(smoothstep(0.0, 15.0, (end - j) as f64));
                self.ledges[j] = (side * ease) as f32;
                self.ledge_wall[j] = wall as f32;
                self.ledge_drop[j] = drop as f32;
            }
            i = end + 100;
        }
    }

    fn make_rivers(&mut self, rng: &mut Pcg) {
        self.rivers.clear();
        let n = self.points.len();
        let count = if self.length < 2500.0 { 1 } else { 2 };
        let mut tries = 0;
        while self.rivers.len() < count && tries < 40 {
            tries += 1;
            let c = rng.randi_range(150, n as i32 - 150) as usize;
            let mut clear = true;
            for j in c - 40..c + 40 {
                if self.ledges[j] != 0.0 || ((j as i64 - c as i64).abs() < 20 && (self.curvature[j] as f64).abs() > 1.0 / 90.0) {
                    clear = false;
                    break;
                }
            }
            for r in &self.rivers {
                if (r.cross as i64 - c as i64).abs() < 250 {
                    clear = false;
                }
            }
            if !clear {
                continue;
            }
            let mut ford = rng.randf_global() < 0.5;
            let half = rng.randf_range(2.5, 4.5);
            let depth = rng.randf_range(0.7, 1.3);
            let right = v2(-self.dirs[c].z, self.dirs[c].x);
            let mut land = f64::INFINITY;
            for k in -4i64..5 {
                let pk = self.points[(c as i64 + k) as usize];
                let q = v2(pk.x, pk.z);
                for sgn in [-1.0f32, 1.0] {
                    let b = q + (right * sgn) * ((self.widths[c] as f64 + 4.0) as f32);
                    land = land.min(self.ground(b.x as f64, b.y as f64));
                }
            }
            let road_h = self.points[c].y as f64;
            let mut level = if ford { (land - 0.3).min(road_h + 0.22) } else { (land - 0.5).min(road_h - 2.0) };
            if ford {
                let dip = road_h - (level - 0.22);
                if dip > 3.0 {
                    ford = false;
                    level = (land - 0.5).min(road_h - 2.0);
                } else {
                    let sigma = 6.0 + dip * 4.0;
                    let reach = (sigma * 2.5) as i64;
                    for j in c as i64 - reach..c as i64 + reach + 1 {
                        let x = (j - c as i64) as f64 / sigma;
                        let y = &mut self.points[j as usize].y;
                        *y = (*y as f64 - dip * (-x * x).exp()) as f32;
                    }
                }
            }
            let heading = right.angle() as f64 + rng.randf_range(-0.4, 0.4);
            let half_len = 75;
            let mut up_pts = Vec::new();
            let mut down_pts = Vec::new();
            for way in [1.0f64, -1.0] {
                let mut p = v2(self.points[c].x, self.points[c].z);
                let mut hd = if way > 0.0 { heading } else { heading + std::f64::consts::PI };
                for k in 0..half_len {
                    hd += self.detail.get_1d((k as f64 * 3.1 + way * 50.0 + c as f64) as f32) as f64 * 0.35;
                    p += v2(hd.cos() as f32, hd.sin() as f32) * RIVER_STEP as f32;
                    if way > 0.0 { down_pts.push(p) } else { up_pts.push(p) }
                }
            }
            let mut pts: Vec<V2> = up_pts.iter().rev().cloned().collect();
            pts.push(v2(self.points[c].x, self.points[c].z));
            pts.extend(down_pts.iter().cloned());
            let mid = up_pts.len();
            let mut levels = vec![0.0f32; pts.len()];
            levels[mid] = level as f32;
            let flat = 18;
            for k in (0..mid).rev() {
                let t = self.ground(pts[k].x as f64, pts[k].y as f64) - 0.6;
                let nx = levels[k + 1] as f64;
                levels[k] = if mid - k < flat { nx } else { nx.max(t.min(nx + 0.12 * RIVER_STEP)) } as f32;
            }
            for k in mid + 1..pts.len() {
                let t = self.ground(pts[k].x as f64, pts[k].y as f64) - 0.6;
                let pv = levels[k - 1] as f64;
                levels[k] = if k - mid < flat { pv } else { pv.min(t.max(pv - 0.12 * RIVER_STEP)) } as f32;
            }
            let mut wet = vec![0u8; pts.len()];
            for k in 0..pts.len() {
                let g = self.ground(pts[k].x as f64, pts[k].y as f64);
                let l = levels[k] as f64;
                wet[k] = (g > l - 0.3 && g < l + 9.0) as u8;
            }
            wet[mid] = 1;
            self.rivers.push(River { pts, levels, wet, half, depth, cross: c, ford });
        }
        self.index_rivers();
    }

    fn index_rivers(&mut self) {
        let mut h: HashMap<Cell, Vec<(usize, usize)>> = HashMap::new();
        for (ri, r) in self.rivers.iter().enumerate() {
            for (k, p) in r.pts.iter().enumerate() {
                h.entry(cell_of(p.x as f64, p.y as f64)).or_default().push((ri, k));
            }
        }
        self.river_candidates = neighbourhoods(&h);
    }

    /// Nearest stream point within `reach`: (river, point, distance, level).
    fn river_near(&self, x: f64, z: f64, reach: f64) -> Option<(usize, usize, f64, f64)> {
        if self.rivers.is_empty() {
            return None;
        }
        let q = v2(x as f32, z as f32);
        let mut best = None;
        let mut best_d = reach * reach;
        for &(ri, k) in self.river_candidates.get(&cell_of(x, z)).map(|v| v.as_slice()).unwrap_or(&[]) {
            let d = q.distance_squared_to(self.rivers[ri].pts[k]) as f64;
            if d < best_d {
                best_d = d;
                best = Some((ri, k));
            }
        }
        let (ri, k) = best?;
        let r = &self.rivers[ri];
        let mut bd = f64::INFINITY;
        let mut level = 0.0;
        for s in [k as i64 - 1, k as i64] {
            if s < 0 || s as usize + 1 >= r.pts.len() {
                continue;
            }
            let s = s as usize;
            let (a, b) = (r.pts[s], r.pts[s + 1]);
            let t = ((q - a).dot(b - a) as f64 / (b - a).length_squared() as f64).clamp(0.0, 1.0);
            let d = q.distance_to(a.lerp(b, t as f32)) as f64;
            if d < bd {
                bd = d;
                level = lerp(r.levels[s] as f64, r.levels[s + 1] as f64, t);
            }
        }
        Some((ri, k, bd, level))
    }

    /// Water surface height at (x, z), or -inf where it is dry.
    pub fn water_level(&self, x: f64, z: f64) -> f64 {
        match self.river_near(x, z, 12.0) {
            Some((ri, k, d, level)) => {
                let r = &self.rivers[ri];
                if r.wet[k] == 0 || d > r.half + 0.5 { f64::NEG_INFINITY } else { level }
            }
            None => f64::NEG_INFINITY,
        }
    }

    fn index(&mut self) {
        self.hash.clear();
        for (i, p) in self.points.iter().enumerate() {
            self.hash.entry(cell_of(p.x as f64, p.z as f64)).or_default().push(i as i32);
        }
        self.locate_candidates = neighbourhoods(&self.hash);
    }

    /// Nearest centre-line point to `p`, horizontally.
    pub fn locate(&self, p: V3, hint: i64) -> Located {
        let mut best = -1i64;
        let mut best_d = f64::INFINITY;
        let n = self.points.len() as i64;
        let d2 = |j: usize| {
            let q = self.points[j];
            v2((q.x as f64 - p.x as f64) as f32, (q.z as f64 - p.z as f64) as f32).length_squared() as f64
        };
        if hint >= 0 {
            for j in (hint - 30).max(0)..(hint + 30).min(n) {
                let d = d2(j as usize);
                if d < best_d {
                    best_d = d;
                    best = j;
                }
            }
            if best_d < 30.0 * 30.0 {
                return self.result(p, best as usize);
            }
        }
        if let Some(c) = self.locate_candidates.get(&cell_of(p.x as f64, p.z as f64)) {
            for &j in c {
                let d = d2(j as usize);
                if d < best_d {
                    best_d = d;
                    best = j as i64;
                }
            }
        }
        if best < 0 {
            return Located::NONE;
        }
        self.result(p, best as usize)
    }

    fn result(&self, p: V3, i: usize) -> Located {
        let d = self.dirs[i];
        let rel = p - self.points[i];
        let (rx, rz) = (rel.x as f64, rel.z as f64);
        let t = (rx * d.x as f64 + rz * d.z as f64).clamp(-STEP, STEP);
        let right = v3(-d.z, 0.0, d.x);
        let offset = rx * right.x as f64 + rz * right.z as f64;
        let j = (i as i64 + if t > 0.0 { 1 } else { -1 }).clamp(0, self.points.len() as i64 - 1) as usize;
        let h = lerp(self.points[i].y as f64, self.points[j].y as f64, t.abs() / STEP);
        Located { index: i as i64, along: i as f64 * STEP + t, offset, height: h, right }
    }

    pub fn point_at(&self, along: f64) -> V3 {
        let f = (along / STEP).clamp(0.0, self.points.len() as f64 - 1.001);
        let i = f as usize;
        self.points[i].lerp(self.points[i + 1], (f - i as f64) as f32)
    }

    fn row(&self, along: f64, len: usize) -> usize {
        ((along / STEP) as i64).clamp(0, len as i64 - 1) as usize
    }

    pub fn dir_at(&self, along: f64) -> V3 {
        self.dirs[self.row(along, self.dirs.len())]
    }

    pub fn width_at(&self, along: f64) -> f64 {
        self.widths[self.row(along, self.widths.len())] as f64
    }

    pub fn curvature_at(&self, along: f64) -> f64 {
        self.curvature[self.row(along, self.curvature.len())] as f64
    }

    pub fn surface_at(&self, p: V3) -> Surface {
        self.surface_near(p, -1).0
    }

    /// Surface at `p` and the road index found (pass it back as the hint).
    pub fn surface_near(&self, p: V3, hint: i64) -> (Surface, i64) {
        let r = self.locate(p, hint);
        (self.surface_from(&r), r.index)
    }

    fn surface_from(&self, r: &Located) -> Surface {
        let off = r.offset.abs();
        let w = self.width_at(r.along);
        if off < w - 0.9 {
            self.road_surface_at(r.along)
        } else if off < w + 0.6 {
            Surface::Loose
        } else {
            Surface::Grass
        }
    }

    /// Natural ground without the road.
    pub fn ground(&self, x: f64, z: f64) -> f64 {
        self.noise.get_2d(x as f32, z as f32) as f64 * 34.0 + self.detail.get_2d(x as f32, z as f32) as f64 * 3.0
    }

    fn carve(&self, x: f64, z: f64, h: f64) -> f64 {
        let Some((ri, _, d, level)) = self.river_near(x, z, 40.0) else {
            return h;
        };
        let r = &self.rivers[ri];
        let half = r.half;
        let mut bed = level - r.depth * (1.0 - smoothstep(half * 0.45, half, d)) + 0.25 * smoothstep(half * 0.8, half, d);
        bed += (d - half).max(0.0) * 0.5;
        h.min(bed)
    }

    pub fn height_near(&self, x: f64, z: f64, near: i64) -> f64 {
        self.carve(x, z, self.height_near_raw(x, z, near))
    }

    fn height_near_raw(&self, x: f64, z: f64, near: i64) -> f64 {
        let natural = self.ground(x, z);
        if near < 0 {
            return natural;
        }
        let near = near as usize;
        let r = self.result(v3(x as f32, 0.0, z as f32), near);
        let off = r.offset.abs();
        if off > REACH {
            return natural;
        }
        let w = self.widths[near] as f64;
        let road_h = r.height - 0.06 * (off / w).clamp(0.0, 1.0);
        if off < w + 0.8 {
            return road_h - 0.08;
        }
        let dx = off - (w + 2.2);
        let ditch = -0.55 * (-dx * dx / 0.9).exp();
        let reach = ((natural - road_h).abs() / 0.32).clamp(12.0, 60.0);
        let blend = smoothstep(w + 3.0, w + 3.0 + reach, off);
        let normal = lerp(road_h, natural, blend) + ditch * (1.0 - blend * 0.6);
        let ledge = self.ledges[near] as f64;
        if ledge == 0.0 {
            return normal;
        }
        let back = smoothstep(w + 14.0, REACH - 5.0, off);
        if signf(r.offset) == signf(ledge) {
            let face = smoothstep(w + 2.4, w + 7.0, off);
            let mut rock = road_h
                + self.ledge_wall[near] as f64 * face
                + self.detail.get_2d((x * 3.0) as f32, (z * 3.0) as f32) as f64 * 1.4 * face * (1.0 - face);
            rock = lerp(rock, natural, back);
            return lerp(normal, normal.max(rock), ledge.abs());
        }
        let mut fall = road_h - 0.1 - self.ledge_drop[near] as f64 * smoothstep(w + 1.9, w + 11.0, off);
        fall = lerp(fall, natural, back);
        lerp(normal, normal.min(fall), ledge.abs())
    }

    pub fn height(&self, x: f64, z: f64) -> f64 {
        self.height_near(x, z, self.nearest_index(x, z))
    }

    pub fn nearest_index(&self, x: f64, z: f64) -> i64 {
        let c = cell_of(x, z);
        let mut best = -1i64;
        let mut best_d = REACH * REACH;
        for dx in -3..=3 {
            for dy in -3..=3 {
                if let Some(list) = self.hash.get(&(c.0 + dx, c.1 + dy)) {
                    for &j in list {
                        let p = self.points[j as usize];
                        let d = v2((p.x as f64 - x) as f32, (p.z as f64 - z) as f32).length_squared() as f64;
                        if d < best_d {
                            best_d = d;
                            best = j as i64;
                        }
                    }
                }
            }
        }
        best
    }

    /// Runs of consecutive road indices that may be nearest to anything in
    /// the square.
    pub fn runs_near(&self, x0: f64, z0: f64, size: f64, margin: f64) -> Vec<Vec<i32>> {
        let mut idx = Vec::new();
        let c0 = cell_of(x0 - margin, z0 - margin);
        let c1 = cell_of(x0 + size + margin, z0 + size + margin);
        for cx in c0.0..=c1.0 {
            for cy in c0.1..=c1.1 {
                if let Some(list) = self.hash.get(&(cx, cy)) {
                    for &j in list {
                        let p = self.points[j as usize];
                        let (px, pz) = (p.x as f64, p.z as f64);
                        if px > x0 - margin && px < x0 + size + margin && pz > z0 - margin && pz < z0 + size + margin {
                            idx.push(j);
                        }
                    }
                }
            }
        }
        idx.sort();
        let mut runs: Vec<Vec<i32>> = Vec::new();
        for j in idx {
            match runs.last_mut() {
                Some(r) if j - r[r.len() - 1] <= 3 => r.push(j),
                _ => runs.push(vec![j]),
            }
        }
        runs
    }

    fn pace_notes(&mut self) {
        self.notes.clear();
        let n = self.curvature.len();
        let mut i = 0;
        while i < n {
            let k = self.curvature[i] as f64;
            if k.abs() > 1.0 / 300.0 {
                let mut j = i;
                let mut peak = 0.0f64;
                let mut turn = 0.0f64;
                while j < n && (self.curvature[j] as f64).abs() > 1.0 / 400.0 && signf(self.curvature[j] as f64) == signf(k) {
                    peak = peak.max((self.curvature[j] as f64).abs());
                    turn += (self.curvature[j] as f64).abs() * STEP;
                    j += 1;
                }
                if turn > 12.0f64.to_radians_godot() {
                    let radius = 1.0 / peak;
                    let mut grade = 6;
                    for (lim, g) in [(20.0, 1), (32.0, 2), (50.0, 3), (80.0, 4), (125.0, 5)] {
                        if radius < lim {
                            grade = g;
                            break;
                        }
                    }
                    if radius < 17.0 {
                        grade = 0;
                    }
                    self.notes.push(Note { at: i as f64 * STEP, kind: if k > 0.0 { "left" } else { "right" }, grade, end: j as f64 * STEP });
                }
                i = j + 1;
            } else {
                i += 1;
            }
        }
        let np = self.points.len();
        let mut j = 10;
        while np >= 20 && j < np - 10 {
            let before = self.points[j].y as f64 - self.points[j - 6].y as f64;
            let after = self.points[j + 6].y as f64 - self.points[j].y as f64;
            if before - after > 0.9 {
                let far = self.notes.last().map(|n| (n.at - j as f64 * STEP).abs() > 40.0).unwrap_or(true);
                if far {
                    self.notes.push(Note { at: j as f64 * STEP, kind: "crest", grade: 0, end: j as f64 * STEP });
                }
            }
            j += 4;
        }
        // Godot's sort_custom is not stable; ties do not occur in practice
        // because corners and crests are 40 m apart.
        self.notes.sort_by(|a, b| a.at.partial_cmp(&b.at).unwrap());
    }
}

trait DegToRad {
    fn to_radians_godot(self) -> f64;
}

impl DegToRad for f64 {
    /// Godot's `deg_to_rad`: x * (PI / 180).
    fn to_radians_godot(self) -> f64 {
        self * (std::f64::consts::PI / 180.0)
    }
}

/// For every cell next to an occupied one: the 3x3 neighbourhood's entries,
/// in the order dx -1..1, dy -1..1 (the order Godot's loops visit them).
fn neighbourhoods<T: Clone>(index: &HashMap<Cell, Vec<T>>) -> HashMap<Cell, Vec<T>> {
    let mut out: HashMap<Cell, Vec<T>> = HashMap::new();
    for &(cx, cy) in index.keys() {
        for dx in -1..=1 {
            for dy in -1..=1 {
                let q = (cx + dx, cy + dy);
                if out.contains_key(&q) {
                    continue;
                }
                let mut list = Vec::new();
                for ex in -1..=1 {
                    for ey in -1..=1 {
                        if let Some(v) = index.get(&(q.0 + ex, q.1 + ey)) {
                            list.extend(v.iter().cloned());
                        }
                    }
                }
                out.insert(q, list);
            }
        }
    }
    out
}

fn pick_grade(rng: &mut Pcg) -> usize {
    let r = rng.randf_global() as f64;
    match r {
        r if r < 0.06 => 0,
        r if r < 0.20 => 1,
        r if r < 0.42 => 2,
        r if r < 0.64 => 3,
        r if r < 0.80 => 4,
        r if r < 0.92 => 5,
        _ => 6,
    }
}
