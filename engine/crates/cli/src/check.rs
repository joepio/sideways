//! Compare the Rust stage with what Godot computed (tools/oracle_dump.gd).

use gdcompat::Pcg;
use serde_json::Value;
use sideways::builder;
use sideways::stage::{RUNOUT, Stage};

struct Report {
    failed: usize,
}

impl Report {
    fn line(&mut self, name: &str, ok: bool, detail: String) {
        if !ok {
            self.failed += 1;
        }
        println!("{} {name:<16} {detail}", if ok { "ok  " } else { "FAIL" });
    }

    /// Compare two float lists; report count, max difference and first mismatch.
    fn floats(&mut self, name: &str, got: &[f64], want: &[Value]) {
        let want: Vec<f64> = want.iter().map(|v| v.as_f64().unwrap_or(f64::NAN)).collect();
        if got.len() != want.len() {
            self.line(name, false, format!("length {} vs godot {}", got.len(), want.len()));
            return;
        }
        let mut max = 0.0f64;
        let mut first = None;
        for (i, (a, b)) in got.iter().zip(&want).enumerate() {
            let d = (a - b).abs();
            // Godot's JSON printer is off by an ulp or so at 17 digits.
            let printed = d <= 1e-12 * a.abs().max(1.0);
            if !(printed || (a.is_infinite() && b.is_infinite())) {
                max = max.max(d);
                first.get_or_insert((i, *a, *b));
            }
        }
        match first {
            None => self.line(name, true, format!("{} values match", got.len())),
            Some((i, a, b)) => self.line(name, false, format!("{} values, max diff {max:.3e}, first at {i}: {a} vs {b}", got.len())),
        }
    }
}

pub fn run(path: &str, seed: u64, km: f64) -> i32 {
    let text = std::fs::read_to_string(path).expect("oracle file");
    let o: Value = serde_json::from_str(&text).expect("oracle json");
    let mut r = Report { failed: 0 };
    let t0 = std::time::Instant::now();
    let mut rng = Pcg::new(seed);
    let weather = rng.next_u32() % 4;
    r.line("weather draw", weather as i64 == o["weather_draw"].as_i64().unwrap(), format!("{weather}"));
    let s = Stage::generate(&mut rng, km * 1000.0 + RUNOUT);
    let layout_ms = t0.elapsed().as_secs_f64() * 1e3;
    let seeds = [s.noise_seed as i64, s.detail_seed as i64];
    r.line("noise seeds", o["noise_seeds"][0].as_i64() == Some(seeds[0]) && o["noise_seeds"][1].as_i64() == Some(seeds[1]), format!("{seeds:?}"));
    let next = rng.randf_global() as f64;
    r.line("rng after", o["next_randf"].as_f64() == Some(next), format!("{next}"));
    let flat = |vs: Vec<[f32; 3]>| vs.into_iter().flatten().map(|x| x as f64).collect::<Vec<_>>();
    let want_pts: Vec<Value> = o["points"].as_array().unwrap().iter().flat_map(|p| p.as_array().unwrap().clone()).collect();
    r.floats("points", &flat(s.points.iter().map(|p| [p.x, p.y, p.z]).collect()), &want_pts);
    let f32s = |v: &[f32]| v.iter().map(|x| *x as f64).collect::<Vec<_>>();
    r.floats("widths", &f32s(&s.widths), o["widths"].as_array().unwrap());
    r.floats("curvature", &f32s(&s.curvature), o["curvature"].as_array().unwrap());
    r.floats("ledges", &f32s(&s.ledges), o["ledges"].as_array().unwrap());
    r.floats("ledge walls", &f32s(&s.ledge_wall), o["ledge_wall"].as_array().unwrap());
    let surf: Vec<f64> = s.road_surfaces.iter().map(|x| *x as f64).collect();
    r.floats("road surfaces", &surf, o["road_surfaces"].as_array().unwrap());
    let want_rivers = o["rivers"].as_array().unwrap();
    r.line("rivers", want_rivers.len() == s.rivers.len(), format!("{} ({})", s.rivers.len(), s.rivers.iter().map(|r| format!("{} {}", r.cross, if r.ford { "ford" } else { "bridge" })).collect::<Vec<_>>().join(", ")));
    for (k, (a, b)) in s.rivers.iter().zip(want_rivers).enumerate() {
        let pts: Vec<f64> = a.pts.iter().flat_map(|p| [p.x as f64, p.y as f64]).collect();
        let wp: Vec<Value> = b["pts"].as_array().unwrap().iter().flat_map(|p| p.as_array().unwrap().clone()).collect();
        r.floats(&format!("river {k} points"), &pts, &wp);
        r.floats(&format!("river {k} levels"), &f32s(&a.levels), b["levels"].as_array().unwrap());
        r.line(&format!("river {k} shape"), b["half"].as_f64() == Some(a.half) && b["depth"].as_f64() == Some(a.depth) && b["ford"].as_bool() == Some(a.ford), format!("half {:.3} depth {:.3}", a.half, a.depth));
    }
    let notes: Vec<f64> = s.notes.iter().flat_map(|n| [n.at, n.grade as f64, n.end]).collect();
    let wn: Vec<Value> = o["notes"].as_array().unwrap().iter().flat_map(|n| vec![n["at"].clone(), n["grade"].clone(), n["end"].clone()]).collect();
    r.floats("pace notes", &notes, &wn);
    // Heights, surfaces, water and nearest index around the road.
    let mut got = Vec::new();
    let mut want = Vec::new();
    for q in o["heights"].as_array().unwrap() {
        let q = q.as_array().unwrap();
        let (x, z) = (q[0].as_f64().unwrap(), q[1].as_f64().unwrap());
        let water = s.water_level(x, z);
        got.extend([s.height(x, z), s.surface_at(gdcompat::math::v3(x as f32, 0.0, z as f32)) as u8 as f64, if water.is_finite() { water } else { -1e30 }, s.nearest_index(x, z) as f64]);
        want.extend(q[2..6].iter().cloned());
    }
    r.floats("height queries", &got, &want);
    let t1 = std::time::Instant::now();
    let cells = builder::chunk_cells(&s);
    r.line("chunks", o["chunk_count"].as_u64() == Some(cells.len() as u64), format!("{}", cells.len()));
    for c in o["chunks"].as_array().unwrap() {
        let cell = (c["c"][0].as_i64().unwrap() as i32, c["c"][1].as_i64().unwrap() as i32);
        let ch = builder::terrain_chunk(&s, cell);
        // Godot's hs carries one cell of padding; compare the inner grid.
        let m = builder::N + 2;
        let whs = c["hs"].as_array().unwrap();
        let mut inner = Vec::new();
        for j in 0..builder::N {
            for i in 0..builder::N {
                inner.push(whs[(j + 1) * m + i + 1].clone());
            }
        }
        r.floats(&format!("chunk {:?} h", cell), &f32s(&ch.heights), &inner);
        let trees: Vec<f64> = ch.trees.iter().flat_map(|t| [t.pos.0 as f64, t.pos.1 as f64, t.pos.2 as f64]).collect();
        let wt: Vec<Value> = c["trees"].as_array().unwrap().iter().flat_map(|t| t.as_array().unwrap()[..3].to_vec()).collect();
        r.floats(&format!("chunk {:?} trees", cell), &trees, &wt);
    }
    let rd = builder::road(&s);
    let faces: Vec<_> = rd.tris.iter().flatten().map(|&i| rd.verts[i as usize]).collect();
    let sum = faces.iter().fold([0.0f32; 3], |a, f| [a[0] + f.x, a[1] + f.y, a[2] + f.z]);
    let rf = o["road_faces"].as_array().unwrap();
    r.floats("road faces", &[faces.len() as f64, sum[0] as f64, sum[1] as f64, sum[2] as f64, faces[0].y as f64, faces[faces.len() - 1].y as f64], &[rf[0].clone(), rf[1].clone(), rf[2].clone(), rf[3].clone(), rf[5].clone(), rf[7].clone()]);
    println!("time: layout {layout_ms:.1} ms, chunks+road {:.1} ms", t1.elapsed().as_secs_f64() * 1e3);
    println!("{}", if r.failed == 0 { "check: ok".to_string() } else { format!("check: {} failed", r.failed) });
    if r.failed == 0 { 0 } else { 1 }
}
