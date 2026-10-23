//! `sideways gpu-run`: the GPU runner's jobs (gpu-jobs.toml), all offscreen.
//! Writes PNGs, results.json and summary.md to the output folder.

use serde_json::{Value, json};
use std::path::Path;

pub fn run(out: &str, jobs_path: &str) -> i32 {
    let out = Path::new(out);
    if let Err(e) = std::fs::create_dir_all(out) {
        eprintln!("{}: {e}", out.display());
        return 2;
    }
    let jobs: toml::Table = match std::fs::read_to_string(jobs_path).map_err(|e| e.to_string()).and_then(|t| t.parse().map_err(|e: toml::de::Error| e.to_string())) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("{jobs_path}: {e}");
            return 2;
        }
    };
    let t = render::Stopwatch::start();
    let gpu = match render::Gpu::new() {
        Ok(g) => g,
        Err(e) => {
            let _ = std::fs::write(out.join("error.txt"), &e);
            eprintln!("{e}");
            return 1;
        }
    };
    let info = gpu.summary();
    let mut results = vec![json!({"job": "init", "ms": t.ms()})];
    let mut summary = format!("GPU: {} ({}, {})\n", info.name, info.backend, info.device_type);
    for job in jobs.get("job").and_then(|j| j.as_array()).cloned().unwrap_or_default() {
        let kind = job.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        let size = job.get("size").and_then(|s| s.as_array()).map(|a| (a[0].as_integer().unwrap_or(640) as u32, a[1].as_integer().unwrap_or(360) as u32)).unwrap_or((640, 360));
        let t = render::Stopwatch::start();
        let r: Value = match kind {
            "info" => json!({"job": "info", "name": info.name, "backend": info.backend, "driver": info.driver, "type": info.device_type, "timestamps": info.timestamps}),
            "test-frame" => {
                let px = render::test_frame(&gpu, size.0, size.1);
                let file = out.join("test-frame.png");
                let ok = render::write_png(&file, size.0, size.1, &px);
                json!({"job": "test-frame", "ok": ok.is_ok(), "ms": t.ms(), "file": "test-frame.png"})
            }
            other => json!({"job": other, "error": "unknown job kind"}),
        };
        summary.push_str(&format!("{kind}: {}\n", r));
        results.push(r);
    }
    let _ = std::fs::write(out.join("results.json"), serde_json::to_string_pretty(&results).unwrap());
    let _ = std::fs::write(out.join("summary.md"), &summary);
    print!("{summary}");
    0
}
