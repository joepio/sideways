//! Kern: the engine core. A game is a deterministic `Sim` advanced in fixed
//! ticks. Around it the engine offers the tools that make iterating fast,
//! for a person or an AI: per-tick state digests, finding the first tick
//! where two runs diverge, tracing any queried value over time as a compact
//! table, timings per system, and snapshots for rewinding.
//!
//! Everything a tool prints is meant to be short: summaries and the first
//! difference, not dumps.

use serde_json::Value;
use sha2::{Digest as _, Sha256};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::time::Instant;

/// A deterministic simulation: the same inputs from the same state always
/// give the same next state, bit for bit.
pub trait Sim {
    /// Advance one fixed tick.
    fn step(&mut self, timings: &mut Timings);
    /// Ticks taken so far.
    fn tick(&self) -> u64;
    /// Feed everything that matters about the state into the digest.
    fn digest(&self, d: &mut Digest);
    /// Introspection: the value at a path such as `cars.0.speed` or
    /// `cars.1.wheels.2.load`, without adding a print and rebuilding.
    fn query(&self, path: &str) -> Option<Value>;
}

/// Hashes state for determinism checks. Floats go in by their bits.
#[derive(Default)]
pub struct Digest(Sha256);

impl Digest {
    pub fn f32(&mut self, x: f32) {
        self.0.update(x.to_bits().to_le_bytes());
    }
    pub fn f64(&mut self, x: f64) {
        self.0.update(x.to_bits().to_le_bytes());
    }
    pub fn u64(&mut self, x: u64) {
        self.0.update(x.to_le_bytes());
    }
    pub fn bytes(&mut self, b: &[u8]) {
        self.0.update(b);
    }
    pub fn hex16(self) -> String {
        let out = self.0.finalize();
        out.iter().take(8).fold(String::new(), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
    }
}

pub fn digest_of<S: Sim>(sim: &S) -> String {
    let mut d = Digest::default();
    sim.digest(&mut d);
    d.hex16()
}

/// Wall time per named system, accumulated over a run.
#[derive(Default, Clone)]
pub struct Timings {
    spans: BTreeMap<&'static str, (u128, u64)>,
}

impl Timings {
    /// Time one system: `timings.span("tyres", || ...)`.
    pub fn span<R>(&mut self, name: &'static str, f: impl FnOnce() -> R) -> R {
        let t = Instant::now();
        let r = f();
        let e = self.spans.entry(name).or_default();
        e.0 += t.elapsed().as_nanos();
        e.1 += 1;
        r
    }

    pub fn add(&mut self, name: &'static str, nanos: u128) {
        let e = self.spans.entry(name).or_default();
        e.0 += nanos;
        e.1 += 1;
    }

    /// One line per system: total ms and microseconds per call.
    pub fn table(&self) -> String {
        let mut rows: Vec<_> = self.spans.iter().collect();
        rows.sort_by(|a, b| b.1.0.cmp(&a.1.0));
        let mut s = String::new();
        for (name, (ns, n)) in rows {
            let _ = writeln!(s, "  {name:<14} {:>9.1} ms {:>8.2} us/call", *ns as f64 / 1e6, *ns as f64 / 1e3 / (*n).max(1) as f64);
        }
        s
    }
}

/// Run `sim` for `ticks`, returning the digest after each `every` ticks.
pub fn run<S: Sim>(sim: &mut S, ticks: u64, timings: &mut Timings) {
    for _ in 0..ticks {
        sim.step(timings);
    }
}

/// Step two sims side by side and report the first tick where their
/// digests differ, with the queried values that differ there.
pub fn first_divergence<A: Sim, B: Sim>(a: &mut A, b: &mut B, ticks: u64, probes: &[&str]) -> Option<String> {
    let mut t = Timings::default();
    for _ in 0..ticks {
        if digest_of(a) != digest_of(b) {
            let mut s = format!("diverged at tick {}\n", a.tick());
            for p in probes {
                let (x, y) = (a.query(p), b.query(p));
                if x != y {
                    let _ = writeln!(s, "  {p}: {} vs {}", short(&x), short(&y));
                }
            }
            return Some(s);
        }
        a.step(&mut t);
        b.step(&mut t);
    }
    None
}

fn short(v: &Option<Value>) -> String {
    match v {
        Some(v) => {
            let s = v.to_string();
            if s.len() > 80 { format!("{}…", &s[..80]) } else { s }
        }
        None => "-".into(),
    }
}

/// Values of some paths sampled over a run, printed as a compact table:
/// one row per sample, plus min/max/mean per numeric column.
pub struct Trace {
    pub paths: Vec<String>,
    pub rows: Vec<(u64, Vec<Option<Value>>)>,
}

impl Trace {
    pub fn new(paths: &[String]) -> Trace {
        Trace { paths: paths.to_vec(), rows: Vec::new() }
    }

    pub fn sample<S: Sim>(&mut self, sim: &S) {
        let vals = self.paths.iter().map(|p| sim.query(p)).collect();
        self.rows.push((sim.tick(), vals));
    }

    pub fn table(&self, max_rows: usize) -> String {
        let mut s = String::new();
        let _ = write!(s, "{:>7}", "tick");
        for p in &self.paths {
            let _ = write!(s, " {:>14}", tail(p, 14));
        }
        s.push('\n');
        let step = (self.rows.len() / max_rows.max(1)).max(1);
        for (i, (tick, vals)) in self.rows.iter().enumerate() {
            if i % step != 0 && i != self.rows.len() - 1 {
                continue;
            }
            let _ = write!(s, "{tick:>7}");
            for v in vals {
                let _ = write!(s, " {:>14}", cell(v));
            }
            s.push('\n');
        }
        for (c, p) in self.paths.iter().enumerate() {
            let xs: Vec<f64> = self.rows.iter().filter_map(|r| r.1[c].as_ref().and_then(|v| v.as_f64())).collect();
            if !xs.is_empty() {
                let lo = xs.iter().cloned().fold(f64::INFINITY, f64::min);
                let hi = xs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                let mean = xs.iter().sum::<f64>() / xs.len() as f64;
                let _ = writeln!(s, "  {p}: min {lo:.4} max {hi:.4} mean {mean:.4}");
            }
        }
        s
    }
}

fn tail(p: &str, n: usize) -> &str {
    if p.len() > n { &p[p.len() - n..] } else { p }
}

fn cell(v: &Option<Value>) -> String {
    match v {
        Some(Value::Number(n)) => match n.as_f64() {
            Some(x) if x.fract() != 0.0 => format!("{x:.4}"),
            _ => n.to_string(),
        },
        Some(v) => tail(&v.to_string(), 14).to_string(),
        None => "-".into(),
    }
}

/// Helpers for `Sim::query`: walk a dotted path through a JSON value.
pub fn walk<'a>(v: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut cur = v;
    for key in path {
        cur = match cur {
            Value::Array(a) => a.get(key.parse::<usize>().ok()?)?,
            Value::Object(o) => o.get(*key)?,
            _ => return None,
        };
    }
    Some(cur)
}
