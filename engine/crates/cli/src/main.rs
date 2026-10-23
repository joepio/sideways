//! `sideways`: the headless tool for the Rust port.
//!
//!   sideways check <oracle.json> [--seed 1] [--km 2]   compare with Godot's output
//!
//! Output is short on purpose: one line per check, and the first mismatch.

mod check;
mod gpu_run;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str, default: &str| -> String {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned().unwrap_or(default.to_string())
    };
    let code = match args.first().map(|s| s.as_str()) {
        Some("bench") => bench(&opt("--car", "rally2"), args.iter().position(|a| a == "--cars").map(|i| args[i + 1].as_str())),
        Some("sim") => sim(&args),
        Some("gpu-run") => gpu_run::run(&opt("--out", "gpu-out"), &opt("--jobs", "gpu-jobs.toml")),
        Some("check") => check::run(&args[1], opt("--seed", "1").parse().unwrap(), opt("--km", "2").parse().unwrap()),
        _ => {
            eprintln!("usage: sideways bench [--car ID] [--cars data/cars.toml]\n       sideways sim [--ticks 45000] [--seed 1] [--km 2] [--trace players.0.kmh,players.0.along] [--events]\n       sideways check <oracle.json> [--seed N] [--km K]");
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

/// Bots race stages, as `godot -- --sim N --seed S --km K` does.
fn sim(args: &[String]) -> i32 {
    use kern::Sim;
    let opt = |name: &str, default: &str| -> String {
        args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned().unwrap_or(default.to_string())
    };
    let ticks: u64 = opt("--ticks", "45000").parse().unwrap();
    let seed: u64 = opt("--seed", "1").parse().unwrap();
    let mut settings = sideways::race::Settings::default();
    settings.stage_km = opt("--km", "3").parse().unwrap();
    settings.rivals = opt("--rivals", "1").parse().unwrap();
    settings.bots = opt("--bots", "1").parse().unwrap();
    if args.iter().any(|a| a == "--weather") {
        settings.weather = Some(opt("--weather", "clear"));
    }
    let cars = match sideways::spec::Cars::load(args.iter().position(|a| a == "--cars").map(|i| args[i + 1].as_str())) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let paths: Vec<String> = args.iter().position(|a| a == "--trace").map(|i| args[i + 1].split(',').map(String::from).collect()).unwrap_or_default();
    let every: u64 = opt("--every", "120").parse().unwrap();
    let from: u64 = opt("--from", "0").parse().unwrap();
    let to: u64 = opt("--to", &u64::MAX.to_string()).parse().unwrap();
    let t0 = std::time::Instant::now();
    let mut timings = kern::Timings::default();
    let mut race = timings.span("first stage", || sideways::race::Race::new(seed, settings, cars));
    let mut trace = kern::Trace::new(&paths);
    for _ in 1..ticks {
        race.step(&mut timings);
        if !paths.is_empty() && race.tick() % every == 0 && race.tick() >= from && race.tick() <= to {
            trace.sample(&race);
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    if args.iter().any(|a| a == "--events") {
        for e in &race.events {
            println!("{e}");
        }
    }
    if !paths.is_empty() {
        print!("{}", trace.table(opt("--rows", "30").parse().unwrap()));
    }
    if let Some(i) = args.iter().position(|a| a == "--probe") {
        let v: Vec<f32> = args[i + 1].split(',').map(|x| x.parse().unwrap()).collect();
        for line in race.probe(v[0], v[1], v.get(2).copied().unwrap_or(2.0)) {
            println!("probe {line}");
        }
    }
    let (stats, hash) = race.summary();
    println!("sim: {} hash {hash}", serde_json::to_string(&stats).unwrap());
    println!("{ticks} ticks ({:.0} s simulated) in {secs:.2} s, {:.0}x realtime", ticks as f64 / 120.0, ticks as f64 / 120.0 / secs);
    print!("{}", timings.table());
    let missing: Vec<&str> = [("stages", stats.stages as f64), ("finishes", stats.finishes as f64), ("shifts", stats.shifts as f64), ("slides", stats.slides)]
        .iter()
        .filter(|(_, v)| *v <= 0.0)
        .map(|(k, _)| *k)
        .collect();
    if missing.is_empty() {
        println!("sim: ok");
        0
    } else {
        println!("sim: never happened: {missing:?}");
        1
    }
}
