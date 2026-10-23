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
            "stage-frame" => stage_frame(&gpu, &job, size, out, &mut summary),
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

/// Render a race moment `repeat` times at `size`; report median GPU time
/// per pass and save the last frame.
fn stage_frame(gpu: &render::Gpu, job: &toml::Value, size: (u32, u32), out: &Path, summary: &mut String) -> Value {
    let get = |k: &str, d: f64| job.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(d);
    let name = job.get("name").and_then(|v| v.as_str()).unwrap_or("stage").to_string();
    let args = crate::shot::ShotArgs {
        out: String::new(),
        seed: get("seed", 1.0) as u64,
        km: get("km", 2.0),
        at: get("at", 300.0),
        frames: get("frames", 400.0) as u64,
        size,
        weather: job.get("weather").and_then(|v| v.as_str()).map(String::from),
        lod_pixels: get("lod", 1.0) as f32,
    };
    let t = render::Stopwatch::start();
    let setup = match crate::shot::prepare(&args) {
        Ok(s) => s,
        Err(e) => return json!({"job": name, "error": e}),
    };
    let prep_ms = t.ms();
    let t = render::Stopwatch::start();
    let renderer = render::Renderer::new(gpu, &setup.scene, &setup.light);
    let upload_ms = t.ms();
    let repeat = get("repeat", 5.0) as usize;
    let mut walls = Vec::new();
    let mut passes: std::collections::BTreeMap<&str, Vec<f64>> = Default::default();
    let mut last = (Vec::new(), render::FrameStats::default());
    for _ in 0..repeat.max(1) {
        let t = render::Stopwatch::start();
        last = renderer.render(gpu, &setup.cam, &setup.light, size.0, size.1);
        walls.push(t.ms());
        for (n, ms) in &last.1.gpu_ms {
            passes.entry(n).or_default().push(*ms);
        }
    }
    let median = |v: &mut Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[v.len() / 2]
    };
    let file = format!("{name}.png");
    let _ = render::write_png(&out.join(&file), size.0, size.1, &last.0);
    let gpu_ms: serde_json::Map<String, Value> = passes.iter_mut().map(|(n, v)| (n.to_string(), json!((median(v) * 100.0).round() / 100.0))).collect();
    let gpu_total: f64 = gpu_ms.values().filter_map(|v| v.as_f64()).sum();
    summary.push_str(&format!("{name} {}x{}: gpu {gpu_total:.2} ms, wall {:.1} ms, {} tris\n", size.0, size.1, median(&mut walls.clone()), last.1.triangles));
    json!({
        "job": name, "size": [size.0, size.1], "file": file,
        "prepare_ms": prep_ms, "upload_ms": upload_ms,
        "wall_ms_median": median(&mut walls), "gpu_ms_median": gpu_ms, "gpu_ms_total": gpu_total,
        "clusters": last.1.clusters, "triangles": last.1.triangles,
        "shadow_clusters": last.1.shadow_clusters, "shadow_triangles": last.1.shadow_triangles,
    })
}
