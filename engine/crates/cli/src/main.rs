//! `sideways`: the headless tool for the Rust port.
//!
//!   sideways check <oracle.json> [--seed 1] [--km 2]   compare with Godot's output
//!
//! Output is short on purpose: one line per check, and the first mismatch.

mod check;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str, default: &str| -> String {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned().unwrap_or(default.to_string())
    };
    let code = match args.first().map(|s| s.as_str()) {
        Some("bench") => bench(&opt("--car", "rally2"), args.iter().position(|a| a == "--cars").map(|i| args[i + 1].as_str())),
        Some("check") => check::run(&args[1], opt("--seed", "1").parse().unwrap(), opt("--km", "2").parse().unwrap()),
        _ => {
            eprintln!("usage: sideways bench [--car ID] [--cars data/cars.toml]\n       sideways check <oracle.json> [--seed N] [--km K]");
            2
        }
    };
    std::process::exit(code);
}

/// Handling bench, side by side with Godot's last numbers.
fn bench(car: &str, cars_path: Option<&str>) -> i32 {
    let cars = match sideways::spec::Cars::load(cars_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let t0 = std::time::Instant::now();
    let r = match sideways::bench::run(&cars, car) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("bench: {e}");
            return 1;
        }
    };
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    let godot: serde_json::Value = serde_json::from_str(include_str!("../../../data/godot_bench.json")).unwrap();
    println!("{:<18} {:>9} {:>9}", "", "rust", "godot");
    for (k, v) in &r.results {
        println!("{k:<18} {:>9} {:>9}", num(v), godot.get(k).map(num).unwrap_or_default());
    }
    println!("{} ticks ({:.0} s simulated) in {ms:.0} ms", r.ticks, r.ticks as f64 / 120.0);
    for f in &r.failures {
        println!("FAIL {f}");
    }
    println!("bench: {}", if r.failures.is_empty() { "ok" } else { "FAILED" });
    if r.failures.is_empty() { 0 } else { 1 }
}

fn num(v: &serde_json::Value) -> String {
    match v.as_f64() {
        Some(x) => {
            let s = format!("{x:.3}");
            s.trim_end_matches('0').trim_end_matches('.').to_string()
        }
        None => v.to_string(),
    }
}
