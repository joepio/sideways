//! Terrain chunks, the road ribbon, barriers and where things grow
//! (src/stage_builder.gd), as plain data: heights, collision triangles and
//! placements. The renderer and the physics both read from this.

use crate::stage::{self, GRID, Stage, STEP};
use gdcompat::math::{V2, V3, signf, v2, v3};
use gdcompat::{Noise, Pcg, Var, hash};
use std::f64::consts::TAU;

/// A placed thing: position, yaw, uniform and vertical scale.
#[derive(Clone, Copy, Debug, serde::Serialize)]
pub struct Spot {
    pub pos: V3Ser,
    pub yaw: f32,
    pub scale: f32,
    pub scale_y: f32,
}

#[derive(Clone, Copy, Debug, serde::Serialize)]
pub struct V3Ser(pub f32, pub f32, pub f32);

impl From<V3> for V3Ser {
    fn from(v: V3) -> Self {
        V3Ser(v.x, v.y, v.z)
    }
}

impl Spot {
    pub fn origin(&self) -> V3 {
        v3(self.pos.0, self.pos.1, self.pos.2)
    }
}

pub struct Chunk {
    pub cell: (i32, i32),
    pub x0: f64,
    pub z0: f64,
    /// n x n heights on the 2 m grid (n = 33).
    pub heights: Vec<f32>,
    /// metres from the road edge per vertex.
    pub road_d: Vec<f32>,
    pub trees: Vec<Spot>,
    pub rocks: Vec<Spot>,
    pub grass: Vec<Spot>,
    pub ferns: Vec<Spot>,
    pub stumps: Vec<Spot>,
}

pub const N: usize = (stage::CHUNK / GRID) as usize + 1;

impl Chunk {
    pub fn vertex(&self, i: usize, j: usize) -> V3 {
        v3((self.x0 + i as f64 * GRID) as f32, self.heights[j * N + i], (self.z0 + j as f64 * GRID) as f32)
    }

    /// Collision triangles, two per grid cell, wound as Godot's.
    pub fn triangles(&self) -> (Vec<V3>, Vec<[u32; 3]>) {
        let mut verts = Vec::with_capacity(N * N);
        for j in 0..N {
            for i in 0..N {
                verts.push(self.vertex(i, j));
            }
        }
        let mut idx = Vec::with_capacity((N - 1) * (N - 1) * 2);
        for j in 0..N - 1 {
            for i in 0..N - 1 {
                let a = (j * N + i) as u32;
                let n = N as u32;
                idx.push([a, a + 1, a + n]);
                idx.push([a + 1, a + n + 1, a + n]);
            }
        }
        (verts, idx)
    }
}

/// The chunks of terrain within CORRIDOR of the road, sorted.
pub fn chunk_cells(s: &Stage) -> Vec<(i32, i32)> {
    let mut seen = std::collections::HashSet::new();
    let reach = (stage::CORRIDOR / stage::CHUNK).ceil() as i32;
    for i in (0..s.points.len()).step_by(8) {
        let p = s.points[i];
        let c = ((p.x as f64 / stage::CHUNK).floor() as i32, (p.z as f64 / stage::CHUNK).floor() as i32);
        for dx in -reach..=reach {
            for dy in -reach..=reach {
                let k = (c.0 + dx, c.1 + dy);
                if seen.contains(&k) {
                    continue;
                }
                let centre = (v2(k.0 as f32, k.1 as f32) + v2(0.5, 0.5)) * stage::CHUNK as f32;
                if (centre.distance_to(v2(p.x, p.z)) as f64) < stage::CORRIDOR {
                    seen.insert(k);
                }
            }
        }
    }
    let mut out: Vec<_> = seen.into_iter().collect();
    out.sort();
    out
}

fn d2(s: &Stage, x: f64, z: f64, i: i32) -> f64 {
    let p = s.points[i as usize];
    (p.x as f64 - x) * (p.x as f64 - x) + (p.z as f64 - z) * (p.z as f64 - z)
}

fn climb(s: &Stage, x: f64, z: f64, mut g: i32, lo: i32, hi: i32) -> i32 {
    let mut d = d2(s, x, z, g);
    while g < hi {
        let e = d2(s, x, z, g + 1);
        if e >= d {
            break;
        }
        d = e;
        g += 1;
    }
    while g > lo {
        let e = d2(s, x, z, g - 1);
        if e >= d {
            break;
        }
        d = e;
        g -= 1;
    }
    g
}

/// One terrain chunk: heights, road distance and what grows on it, with
/// its own random numbers so chunks can be built in parallel.
pub fn terrain_chunk(s: &Stage, c: (i32, i32)) -> Chunk {
    let mut rng = Pcg::new(hash(&Var::Array(&[Var::Int(s.noise_seed as i64), Var::Int(c.0 as i64), Var::Int(c.1 as i64)])) as u64);
    let n = N;
    let x0 = c.0 as f64 * stage::CHUNK;
    let z0 = c.1 as f64 * stage::CHUNK;
    let runs = s.runs_near(x0, z0, stage::CHUNK, stage::REACH + 5.0);
    let mut guesses: Vec<i32> = runs.iter().map(|r| r[r.len() / 2]).collect();
    let m = n + 2;
    let mut hs = vec![0.0f32; m * m];
    let mut road_d = vec![0.0f32; m * m];
    for j in 0..m {
        for i in 0..m {
            let x = x0 + (i as f64 - 1.0) * GRID;
            let z = z0 + (j as f64 - 1.0) * GRID;
            let mut near = -1i64;
            let mut near_d = f64::INFINITY;
            for (ri, r) in runs.iter().enumerate() {
                let g = climb(s, x, z, guesses[ri], r[0], r[r.len() - 1]);
                guesses[ri] = g;
                let p = s.points[g as usize];
                let d = v2((p.x as f64 - x) as f32, (p.z as f64 - z) as f32).length_squared() as f64;
                if d < near_d {
                    near_d = d;
                    near = g as i64;
                }
            }
            if near_d > stage::REACH * stage::REACH {
                near = -1;
            }
            hs[j * m + i] = s.height_near(x, z, near) as f32;
            road_d[j * m + i] = (near_d.sqrt() - if near >= 0 { s.widths[near as usize] as f64 } else { 0.0 }) as f32;
        }
    }
    let mut trees = Vec::new();
    let mut rocks = Vec::new();
    let mut grass = Vec::new();
    let mut ferns = Vec::new();
    let mut stumps = Vec::new();
    let gridf = GRID as f32;
    for j in 0..n {
        for i in 0..n {
            let k = (j + 1) * m + (i + 1);
            let x = x0 + i as f64 * GRID;
            let z = z0 + j as f64 * GRID;
            let dx = hs[k + 1] as f64 - hs[k - 1] as f64;
            let dz = hs[k + m] as f64 - hs[k - m] as f64;
            let normal = v3(-dx as f32, (2.0 * GRID) as f32, -dz as f32).normalized();
            let steep = (normal.y as f64) < 0.75 || (!s.rivers.is_empty() && s.water_level(x, z) > hs[k] as f64 - 0.4);
            let edge = road_d[k] as f64;
            if i < n - 1 && j < n - 1 && edge > 0.7 && edge < 26.0 && !steep {
                let tufts = if edge < 9.0 { 7 } else if rng.randf() < 0.5 { 2 } else { 0 };
                let cx = x + (rng.randf() * gridf) as f64;
                let cz = z + (rng.randf() * gridf) as f64;
                for _ in 0..tufts {
                    let gx = (cx + rng.randf_range_f32(-0.6, 0.6) as f64).clamp(x, x + GRID);
                    let gz = (cz + rng.randf_range_f32(-0.6, 0.6) as f64).clamp(z, z + GRID);
                    let gs = rng.randf_range_f32(0.6, 1.2) as f64 * if edge < 9.0 { 1.0 } else { 0.75 };
                    let fx = (gx - x) / GRID;
                    let fz = (gz - z) / GRID;
                    let l = |a: f32, b: f32, t: f64| a as f64 + (b as f64 - a as f64) * t;
                    let gy = { let a = l(hs[k], hs[k + 1], fx); let b = l(hs[k + m], hs[k + m + 1], fx); a + (b - a) * fz };
                    let yaw = (rng.randf() as f64 * TAU) as f32;
                    let sy = gs as f32 * rng.randf_range_f32(0.8, 1.3);
                    grass.push(Spot { pos: v3(gx as f32, (gy - 0.03) as f32, gz as f32).into(), yaw, scale: gs as f32, scale_y: sy });
                }
            }
            if i < n - 1 && j < n - 1 && (i + j * 3) % 2 == 0 {
                let tx = x + rng.randf_range_f32(0.0, gridf * 2.0) as f64;
                let tz = z + rng.randf_range_f32(0.0, gridf * 2.0) as f64;
                let clear = road_d[k] as f64 - rng.randf_range_f32(4.5, 9.0) as f64;
                let thin = s.detail.get_2d((tx * 0.6) as f32, (tz * 0.6) as f32) as f64;
                if clear > 0.0 && !steep && thin > -0.25 && (rng.randf() as f64) < 0.28 + 0.25 * thin {
                    let ty = s.height(tx, tz);
                    let mut foot = ty;
                    for (ox, oz) in [(0.7f32, 0.0f32), (-0.7, 0.0), (0.0, 0.7), (0.0, -0.7)] {
                        foot = foot.min(s.height(tx + ox as f64, tz + oz as f64));
                    }
                    let sc = rng.randf_range_f32(0.75, 1.25);
                    let yaw = (rng.randf() as f64 * TAU) as f32;
                    let sy = sc * rng.randf_range_f32(0.9, 1.15);
                    trees.push(Spot { pos: v3(tx as f32, (foot - 0.25) as f32, tz as f32).into(), yaw, scale: sc, scale_y: sy });
                } else if clear > 4.0 && !steep && rng.randf() < 0.004 {
                    let sy = s.height(tx, tz);
                    let ss = rng.randf_range_f32(0.8, 1.3);
                    let yaw = (rng.randf() as f64 * TAU) as f32;
                    stumps.push(Spot { pos: v3(tx as f32, (sy - 0.05) as f32, tz as f32).into(), yaw, scale: ss, scale_y: ss });
                } else if clear > 3.0 && !steep && (rng.randf() as f64) < 0.05 + 0.08 * thin.max(0.0) {
                    let fy = s.height(tx, tz);
                    let fs = rng.randf_range_f32(0.7, 1.3);
                    let yaw = (rng.randf() as f64 * TAU) as f32;
                    ferns.push(Spot { pos: v3(tx as f32, (fy - 0.05) as f32, tz as f32).into(), yaw, scale: fs, scale_y: fs });
                } else if clear > -3.0 && clear < 6.0 && rng.randf() < 0.012 {
                    let ry = s.height(tx, tz);
                    let rs = rng.randf_range_f32(0.4, 1.3);
                    // Axis (three draws) then angle: the rock's tumble is
                    // only for looks; keep the draws so the stream matches.
                    let (_ax, _ay, _az) = (rng.randf(), rng.randf(), rng.randf());
                    let yaw = (rng.randf() as f64 * TAU) as f32;
                    rocks.push(Spot { pos: v3(tx as f32, (ry - rs as f64 * 0.2) as f32, tz as f32).into(), yaw, scale: rs, scale_y: rs * 0.7 });
                }
            }
        }
    }
    let mut heights = vec![0.0f32; n * n];
    let mut rd = vec![0.0f32; n * n];
    for j in 0..n {
        for i in 0..n {
            heights[j * n + i] = hs[(j + 1) * m + i + 1];
            rd[j * n + i] = road_d[(j + 1) * m + i + 1];
        }
    }
    Chunk { cell: c, x0, z0, heights, road_d: rd, trees, rocks, grass, ferns, stumps }
}

pub const ACROSS: [f64; 23] = [
    -1.25, -1.0, -0.86, -0.72, -0.58, -0.46, -0.36, -0.28, -0.21, -0.14, -0.07, 0.0, 0.07, 0.14, 0.21, 0.28, 0.36, 0.46, 0.58, 0.72, 0.86, 1.0, 1.25,
];

/// The road ribbon: wheel tracks, the ridge between them and the windrows
/// are real shape, and this is the road collider too.
pub struct Road {
    pub verts: Vec<V3>,
    pub tris: Vec<[u32; 3]>,
    pub cols: usize,
}

pub fn road(s: &Stage) -> Road {
    let cols = ACROSS.len();
    let n = s.points.len();
    let wob = Noise::with_defaults(11, 1.0 / 18.0);
    let mut verts = Vec::with_capacity(n * cols);
    for i in 0..n {
        let p = s.points[i];
        let d = s.dirs[i];
        let right = v3(-d.z, 0.0, d.x);
        let w = s.widths[i] as f64;
        let wander = wob.get_1d((i as f64 * STEP) as f32) as f64 * 0.08;
        let wear = 0.6 + 0.4 * wob.get_1d((i as f64 * STEP * 0.3 + 100.0) as f32) as f64;
        for &a in ACROSS.iter() {
            let mut off = a * w;
            if a.abs() > 1.1 {
                off = signf(a) * (w + 0.8);
            }
            let q = p + right * off as f32;
            let mut y = p.y as f64 - 0.06 * a.abs().min(1.0);
            let rut = (-(((a + wander).abs() - 0.25) / 0.085).powi(2)).exp() * wear;
            let ridge = (-((a + wander) / 0.07).powi(2)).exp() * wear;
            let windrow = (-((a.abs() - 0.8) / 0.08).powi(2)).exp();
            y += -0.045 * rut + 0.025 * ridge + 0.04 * windrow;
            if a.abs() > 1.1 {
                y = s.height_near(q.x as f64, q.z as f64, i as i64) + 0.02;
            }
            verts.push(v3(q.x, y as f32, q.z));
        }
    }
    let mut tris = Vec::with_capacity((n - 1) * (cols - 1) * 2);
    for i in 0..n - 1 {
        for c in 0..cols - 1 {
            let a = (i * cols + c) as u32;
            let cl = cols as u32;
            tris.push([a, a + cl, a + 1]);
            tris.push([a + 1, a + cl, a + cl + 1]);
        }
    }
    Road { verts, tris, cols }
}

/// A box collider: centre, half extents and a horizontal facing.
#[derive(Clone, Copy, Debug)]
pub struct Block {
    pub centre: V3,
    pub half: V3,
    /// Unit direction the box's length (local Z) runs along.
    pub along: V3,
}

/// Walls and Armco along the drop of every ledge, and bridge rails.
pub fn barriers(s: &Stage) -> Vec<Block> {
    let mut out = Vec::new();
    let n = s.points.len();
    let mut i = 0;
    while i < n {
        if (s.ledges[i] as f64).abs() < 0.35 {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < n - 1 && (s.ledges[j + 1] as f64).abs() >= 0.35 {
            j += 1;
        }
        let side = -signf(s.ledges[i] as f64) as f32;
        let mut line: Vec<V3> = Vec::new();
        for k in i..=j {
            let right = v3(-s.dirs[k].z, 0.0, s.dirs[k].x);
            line.push(s.points[k] + right * (side * (s.widths[k] as f64 + 1.3) as f32));
        }
        for k in 0..line.len().saturating_sub(1) {
            let (a, b) = (line[k], line[k + 1]);
            let len = (b - a).length();
            out.push(Block { centre: (a + b) * 0.5 + V3::UP * 0.35, half: v3(0.2, 0.5, (len + 0.3) * 0.5), along: (b - a).normalized() });
        }
        i = j + 1;
    }
    for r in &s.rivers {
        if r.ford {
            continue;
        }
        let c = r.cross as i64;
        let span = ((r.half + 6.0) / STEP).ceil() as i64;
        for k in c - span..=c + span {
            let k = k as usize;
            let (p, f) = (s.points[k], s.dirs[k]);
            let right = v3(-f.z, 0.0, f.x);
            let w = s.widths[k] as f64 + 0.5;
            for sgn in [-1.0f32, 1.0] {
                let edge = p + right * (sgn * (w + 0.1) as f32);
                out.push(Block { centre: edge + V3::UP * 0.55, half: v3(0.125, 0.55, ((STEP + 0.2) * 0.5) as f32), along: f });
            }
        }
    }
    out
}

/// The visible barriers: per ledge, the line along the drop and whether it
/// is an Armco rail (else a dry-stone wall), as stage_builder.gd draws them.
pub struct BarrierLine {
    pub points: Vec<V3>,
    pub rail: bool,
}

pub fn barrier_lines(s: &Stage) -> Vec<BarrierLine> {
    let mut out = Vec::new();
    let n = s.points.len();
    let mut i = 0;
    while i < n {
        if (s.ledges[i] as f64).abs() < 0.35 {
            i += 1;
            continue;
        }
        let mut j = i;
        while j < n - 1 && (s.ledges[j + 1] as f64).abs() >= 0.35 {
            j += 1;
        }
        let side = -signf(s.ledges[i] as f64) as f32;
        let points = (i..=j)
            .map(|k| {
                let right = v3(-s.dirs[k].z, 0.0, s.dirs[k].x);
                s.points[k] + right * (side * (s.widths[k] as f64 + 1.3) as f32)
            })
            .collect();
        out.push(BarrierLine { points, rail: hash(&Var::Int(i as i64)) % 2 == 0 });
        i = j + 1;
    }
    out
}

/// Ground map for anything that needs heights without the physics: the
/// heights of all chunks on one grid.
pub struct GroundMap {
    pub origin: V2,
    pub width: usize,
    pub height: usize,
    pub heights: Vec<f32>,
}
