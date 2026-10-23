//! A headless GPU: no window, no surface. Everything renders into
//! textures and is read back, so the same code runs on a desktop GPU, in CI
//! and on a software rasteriser (lavapipe) in a container.

use std::time::Instant;

pub struct Gpu {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub info: wgpu::AdapterInfo,
    pub features: wgpu::Features,
    pub limits: wgpu::Limits,
}

#[derive(Debug, Clone)]
pub struct GpuInfo {
    pub name: String,
    pub backend: String,
    pub driver: String,
    pub device_type: String,
    pub timestamps: bool,
}

impl Gpu {
    /// The best adapter there is. `KERN_ADAPTER=software` forces the
    /// fallback (lavapipe/WARP); any other value picks the first adapter
    /// whose name contains it.
    pub fn new() -> Result<Gpu, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
        let wanted = std::env::var("KERN_ADAPTER").ok();
        let adapter = pollster::block_on(async {
            if let Some(w) = wanted.as_deref().filter(|w| *w != "software") {
                for a in instance.enumerate_adapters(wgpu::Backends::all()).await {
                    if a.get_info().name.to_lowercase().contains(&w.to_lowercase()) {
                        return Ok(a);
                    }
                }
            }
            instance
                .request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: wgpu::PowerPreference::HighPerformance,
                    force_fallback_adapter: wanted.as_deref() == Some("software"),
                    compatible_surface: None,
                    ..Default::default()
                })
                .await
        })
        .map_err(|e| format!("no GPU adapter: {e}"))?;
        let info = adapter.get_info();
        let optional = wgpu::Features::TIMESTAMP_QUERY | wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS | wgpu::Features::INDIRECT_FIRST_INSTANCE;
        let features = adapter.features() & optional;
        let mut limits = wgpu::Limits::default().using_resolution(adapter.limits());
        let al = adapter.limits();
        limits.max_storage_buffer_binding_size = al.max_storage_buffer_binding_size;
        limits.max_buffer_size = al.max_buffer_size;
        limits.max_storage_buffers_per_shader_stage = al.max_storage_buffers_per_shader_stage.min(16);
        limits.max_compute_workgroups_per_dimension = al.max_compute_workgroups_per_dimension;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("kern"),
            required_features: features,
            required_limits: limits.clone(),
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
            memory_hints: wgpu::MemoryHints::Performance,
            trace: wgpu::Trace::Off,
        }))
        .map_err(|e| format!("device: {e}"))?;
        Ok(Gpu { device, queue, info, features, limits })
    }

    pub fn summary(&self) -> GpuInfo {
        GpuInfo {
            name: self.info.name.clone(),
            backend: format!("{:?}", self.info.backend),
            driver: format!("{} {}", self.info.driver, self.info.driver_info),
            device_type: format!("{:?}", self.info.device_type),
            timestamps: self.features.contains(wgpu::Features::TIMESTAMP_QUERY),
        }
    }

    pub fn wait(&self) {
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
    }

    /// Copy an RGBA8 texture to memory.
    pub fn read_rgba8(&self, tex: &wgpu::Texture) -> Vec<u8> {
        let (w, h) = (tex.width(), tex.height());
        let row = (w * 4).div_ceil(256) * 256;
        let buf = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (row * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut enc = self.device.create_command_encoder(&Default::default());
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo { buffer: &buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(h) } },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        self.queue.submit([enc.finish()]);
        buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        self.wait();
        let data = buf.slice(..).get_mapped_range().expect("mapped readback");
        let mut out = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h {
            let start = (y * row) as usize;
            out.extend_from_slice(&data[start..start + (w * 4) as usize]);
        }
        out
    }
}

pub fn write_png(path: &std::path::Path, w: u32, h: u32, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut wr = enc.write_header().map_err(|e| e.to_string())?;
    wr.write_image_data(rgba).map_err(|e| e.to_string())
}

/// Wall-clock timer for CPU-side stages.
pub struct Stopwatch(Instant);

impl Stopwatch {
    pub fn start() -> Stopwatch {
        Stopwatch(Instant::now())
    }
    pub fn ms(&self) -> f64 {
        self.0.elapsed().as_secs_f64() * 1e3
    }
}
