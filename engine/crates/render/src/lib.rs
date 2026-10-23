//! Kern's renderer. Headless by design: it renders into textures and reads
//! them back, so frames and benchmarks run the same on a desktop GPU and on
//! a software rasteriser, and never open a window unless a game asks.
//!
//! Geometry is Nanite-style: clusters in a LOD DAG (cluster.rs), culled and
//! LOD-selected per cluster on the GPU, rastered into a visibility buffer
//! and shaded once per pixel in HDR (frame.rs).

pub mod cluster;
pub mod frame;
pub mod gpu;
pub mod scene;

pub use frame::{Camera, FrameStats, Lighting, Renderer, ViewRect, split_rects};
pub use gpu::{Gpu, Stopwatch, write_png};
pub use scene::Scene;
/// A test frame: a compute shader fills an RGBA8 image with a gradient.
/// Proves the device, compute, readback and PNG path end to end.
pub fn test_frame(gpu: &Gpu, w: u32, h: u32) -> Vec<u8> {
    let tex = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("test"),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let module = gpu.device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("test"),
        source: wgpu::ShaderSource::Wgsl(
            "@group(0) @binding(0) var out: texture_storage_2d<rgba8unorm, write>;
             @compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
                 let s = vec2<f32>(textureDimensions(out));
                 let uv = vec2<f32>(id.xy) / s;
                 textureStore(out, id.xy, vec4<f32>(uv.x, uv.y, 0.5, 1.0));
             }"
            .into(),
        ),
    });
    let pipe = gpu.device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("test"),
        layout: None,
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    let view = tex.create_view(&Default::default());
    let bind = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &pipe.get_bind_group_layout(0),
        entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) }],
    });
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    {
        let mut pass = enc.begin_compute_pass(&Default::default());
        pass.set_pipeline(&pipe);
        pass.set_bind_group(0, &bind, &[]);
        pass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
    }
    gpu.queue.submit([enc.finish()]);
    gpu.read_rgba8(&tex)
}
