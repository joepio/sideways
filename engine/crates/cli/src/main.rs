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
        Some("check") => check::run(&args[1], opt("--seed", "1").parse().unwrap(), opt("--km", "2").parse().unwrap()),
        _ => {
            eprintln!("usage: sideways check <oracle.json> [--seed N] [--km K]");
            2
        }
    };
    std::process::exit(code);
}
