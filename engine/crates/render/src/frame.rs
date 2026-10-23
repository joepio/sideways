//! The frame: per view, cull clusters on the GPU, raster the survivors
//! into a visibility buffer, shade every pixel once in HDR, tonemap. The
//! sun's shadow map is a view of its own through the same cluster path.

use crate::Gpu;
use crate::scene::Scene;
use bytemuck::{Pod, Zeroable};
use glam::{Mat4, Vec3, Vec4};
use std::f32::consts::PI;
use wgpu::util::DeviceExt;

pub const MAX_VISIBLE: u32 = 4 << 20;
const SHADOW_SIZE: u32 = 4096;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ViewUniform {
    view_proj: [[f32; 4]; 4],
    inv_view_proj: [[f32; 4]; 4],
    cam: [f32; 4],
    planes: [[f32; 4]; 6],
    params: [f32; 4],
    size: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct LightUniform {
    sun_dir: [f32; 4],
    sun_color: [f32; 4],
    shadow_view_proj: [[f32; 4]; 4],
    sky: [f32; 4],
    fog_color: [f32; 4],
    fog: [f32; 4],
    sh: [[f32; 4]; 9],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ToneUniform {
    exposure: f32,
    contrast: f32,
    saturation: f32,
    pad: f32,
}

/// Where the camera is and what it sees.
#[derive(Clone, Copy, Debug)]
pub struct Camera {
    pub pos: Vec3,
    pub target: Vec3,
    pub fov_y: f32,
    pub near: f32,
}

/// Light and look for a frame, in physical units.
#[derive(Clone, Debug)]
pub struct Lighting {
    /// Unit vector towards the sun.
    pub sun_dir: Vec3,
    /// Illuminance of the sun on a surface facing it (lux).
    pub sun_lux: f32,
    pub sun_color: Vec3,
    pub shadow_strength: f32,
    /// Horizontal irradiance of the sky without the sun (lux).
    pub sky_lux: f32,
    /// Exposure value at ISO 100 (sunny 16: about 15).
    pub ev100: f32,
    pub fog_start: f32,
    pub fog_end: f32,
    pub fog_density: f32,
    pub contrast: f32,
    pub saturation: f32,
    /// Cluster error allowed on screen, in pixels.
    pub lod_pixels: f32,
}

impl Lighting {
    /// Set a field by name (`sun_lux=50000`): tune the look without a rebuild.
    pub fn set(&mut self, kv: &str) -> Result<(), String> {
        let (k, v) = kv.split_once('=').ok_or_else(|| format!("expected key=value, got {kv}"))?;
        let f: f32 = v.parse().map_err(|_| format!("{k}: not a number: {v}"))?;
        match k {
            "sun_lux" => self.sun_lux = f,
            "shadow_strength" => self.shadow_strength = f,
            "sky_lux" => self.sky_lux = f,
            "ev100" => self.ev100 = f,
            "fog_start" => self.fog_start = f,
            "fog_end" => self.fog_end = f,
            "fog_density" => self.fog_density = f,
            "contrast" => self.contrast = f,
            "saturation" => self.saturation = f,
            "lod_pixels" => self.lod_pixels = f,
            "sun_elevation" | "sun_azimuth" => {
                let el = if k == "sun_elevation" { f } else { self.sun_dir.y.asin().to_degrees() };
                let az = if k == "sun_azimuth" { f } else { self.sun_dir.x.atan2(-self.sun_dir.z).to_degrees() };
                let (el, az) = (el.to_radians(), az.to_radians());
                self.sun_dir = Vec3::new(az.sin() * el.cos(), el.sin(), -az.cos() * el.cos());
            }
            _ => return Err(format!("unknown light setting {k}")),
        }
        Ok(())
    }
}

impl Default for Lighting {
    fn default() -> Self {
        let el = 30f32.to_radians();
        let az = 125f32.to_radians();
        Lighting {
            sun_dir: Vec3::new(az.sin() * el.cos(), el.sin(), -az.cos() * el.cos()),
            sun_lux: 100_000.0,
            sun_color: Vec3::new(1.0, 0.96, 0.9),
            shadow_strength: 1.0,
            sky_lux: 18_000.0,
            ev100: 14.0,
            fog_start: 140.0,
            fog_end: 750.0,
            fog_density: 0.0,
            contrast: 1.0,
            saturation: 1.0,
            lod_pixels: 1.0,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct FrameStats {
    pub clusters: u32,
    pub triangles: u32,
    pub shadow_clusters: u32,
    pub shadow_triangles: u32,
    /// GPU time per pass in ms, when the GPU has timestamps.
    pub gpu_ms: Vec<(&'static str, f64)>,
    /// For each requested pixel: (instance, cluster, triangle) or None for sky.
    pub picks: Vec<Option<(u32, u32, u32)>>,
}

struct ViewTargets {
    uniform: wgpu::Buffer,
    visible: wgpu::Buffer,
    counter: wgpu::Buffer,
    args: wgpu::Buffer,
    cull_bind: wgpu::BindGroup,
    raster_bind: wgpu::BindGroup,
}

pub struct Renderer {
    scene_bind: wgpu::BindGroup,
    cull: wgpu::ComputePipeline,
    finalize: wgpu::ComputePipeline,
    raster: wgpu::RenderPipeline,
    raster_depth: wgpu::RenderPipeline,
    shade: wgpu::ComputePipeline,
    tone: wgpu::ComputePipeline,
    shade_layout: wgpu::BindGroupLayout,
    tone_layout: wgpu::BindGroupLayout,
    view_cull_layout: wgpu::BindGroupLayout,
    view_raster_layout: wgpu::BindGroupLayout,
    instances: u32,
    sky_view: wgpu::TextureView,
    sky_sh: [[f32; 4]; 9],
    sky_horizon: Vec3,
    sky_scale: f32,
    sky_rotation: f32,
    shadow_samp: wgpu::Sampler,
    query: Option<(wgpu::QuerySet, wgpu::Buffer, wgpu::Buffer)>,
}

fn storage(read_only: bool) -> wgpu::BindingType {
    wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only }, has_dynamic_offset: false, min_binding_size: None }
}

fn uniform() -> wgpu::BindingType {
    wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None }
}

fn layout(gpu: &Gpu, label: &str, entries: &[(u32, wgpu::BindingType)]) -> wgpu::BindGroupLayout {
    let all = wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT | wgpu::ShaderStages::COMPUTE;
    // Writable bindings are for compute only (vertex stages cannot write).
    let writable = |ty: &wgpu::BindingType| matches!(ty, wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: false }, .. } | wgpu::BindingType::StorageTexture { .. });
    let e: Vec<_> = entries
        .iter()
        .map(|(b, ty)| wgpu::BindGroupLayoutEntry { binding: *b, visibility: if writable(ty) { wgpu::ShaderStages::COMPUTE } else { all }, ty: *ty, count: None })
        .collect();
    gpu.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(label), entries: &e })
}

fn buffer(gpu: &Gpu, label: &str, data: &[u8], usage: wgpu::BufferUsages) -> wgpu::Buffer {
    // Storage bindings cannot be empty.
    let pad = [0u8; 16];
    gpu.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some(label), contents: if data.is_empty() { &pad } else { data }, usage })
}

fn bind(gpu: &Gpu, layout: &wgpu::BindGroupLayout, entries: &[(u32, wgpu::BindingResource)]) -> wgpu::BindGroup {
    let e: Vec<_> = entries.iter().map(|(b, r)| wgpu::BindGroupEntry { binding: *b, resource: r.clone() }).collect();
    gpu.device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout, entries: &e })
}

/// Albedo textures as one array with mips (all resized to `size`).
fn texture_array(gpu: &Gpu, scene: &Scene, size: u32) -> wgpu::Texture {
    let layers = scene.textures.len().max(1) as u32;
    let mips = size.ilog2() + 1;
    let tex = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("albedo"),
        size: wgpu::Extent3d { width: size, height: size, depth_or_array_layers: layers },
        mip_level_count: mips,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8UnormSrgb,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    for (layer, t) in scene.textures.iter().enumerate() {
        let mut img = image::imageops::resize(&t.rgba, size, size, image::imageops::FilterType::Triangle);
        let cutout = img.pixels().any(|p| p[3] < 250);
        let target = coverage(&img, 1.0);
        for mip in 0..mips {
            let s = (size >> mip).max(1);
            if mip > 0 {
                img = image::imageops::resize(&img, s, s, image::imageops::FilterType::Triangle);
                if cutout {
                    preserve_coverage(&mut img, target);
                }
            }
            gpu.queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: &tex, mip_level: mip, origin: wgpu::Origin3d { x: 0, y: 0, z: layer as u32 }, aspect: wgpu::TextureAspect::All },
                &img,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * s), rows_per_image: Some(s) },
                wgpu::Extent3d { width: s, height: s, depth_or_array_layers: 1 },
            );
        }
    }
    tex
}

/// Fraction of texels that pass a 0.5 alpha test with alpha scaled by `k`.
fn coverage(img: &image::RgbaImage, k: f32) -> f32 {
    let n = img.pixels().filter(|p| p[3] as f32 * k >= 127.5).count();
    n as f32 / (img.width() * img.height()).max(1) as f32
}

/// Scale a mip's alpha so as many texels pass the alpha test as at full
/// size: foliage keeps its density in the distance instead of thinning out.
fn preserve_coverage(img: &mut image::RgbaImage, target: f32) {
    let (mut lo, mut hi) = (0.25f32, 8.0f32);
    for _ in 0..12 {
        let mid = (lo + hi) * 0.5;
        if coverage(img, mid) < target {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let k = (lo + hi) * 0.5;
    for p in img.pixels_mut() {
        p[3] = (p[3] as f32 * k).min(255.0) as u8;
    }
}

/// SH9 projection of an equirectangular sky (radiance in, irradiance
/// coefficients out), leaving out the sun: the sun is its own light.
fn sky_sh(w: u32, h: u32, px: &[[f32; 4]], rotation: f32, clamp: f32) -> ([[f32; 4]; 9], Vec3) {
    let mut sh = [[0.0f32; 4]; 9];
    let mut horizon = Vec3::ZERO;
    let mut horizon_w = 0.0f32;
    let step = 4;
    for y in (0..h).step_by(step) {
        let theta = (y as f32 + 0.5) / h as f32 * PI;
        let dw = (2.0 * PI / w as f32) * (PI / h as f32) * theta.sin() * (step * step) as f32;
        for x in (0..w).step_by(step) {
            let phi = ((x as f32 + 0.5) / w as f32 - 0.5) * 2.0 * PI;
            // Inverse of sky_dir_uv in the shader.
            let (sx, sz) = (phi.sin() * theta.sin(), -phi.cos() * theta.sin());
            let d = Vec3::new(sx * rotation.cos() + sz * rotation.sin(), theta.cos(), -sx * rotation.sin() + sz * rotation.cos());
            let c = px[(y * w + x) as usize];
            let c = Vec3::new(c[0].min(clamp), c[1].min(clamp), c[2].min(clamp));
            let basis = [
                0.282095,
                0.488603 * d.y,
                0.488603 * d.z,
                0.488603 * d.x,
                1.092548 * d.x * d.y,
                1.092548 * d.y * d.z,
                0.315392 * (3.0 * d.z * d.z - 1.0),
                1.092548 * d.x * d.z,
                0.546274 * (d.x * d.x - d.y * d.y),
            ];
            for k in 0..9 {
                sh[k][0] += c.x * basis[k] * dw;
                sh[k][1] += c.y * basis[k] * dw;
                sh[k][2] += c.z * basis[k] * dw;
            }
            if d.y.abs() < 0.1 {
                horizon += c;
                horizon_w += 1.0;
            }
        }
    }
    // Shader uses Ramamoorthi-Hanrahan coefficient order (y, z, x terms),
    // with s[6] for the z^2 term; this order matches it.
    (sh, horizon / horizon_w.max(1.0))
}

fn eval_irradiance_up(sh: &[[f32; 4]; 9]) -> f32 {
    // Same formula as the shader for n = +Y (the shader's convention).
    let (c1, c2, c4, c5) = (0.429043, 0.511664, 0.886227, 0.247708);
    let g = |k: usize| sh[k][1];
    c1 * g(8) * (-1.0) + c4 * g(0) - c5 * g(6) + 2.0 * c2 * g(1)
}

impl Renderer {
    pub fn new(gpu: &Gpu, scene: &Scene, light: &Lighting) -> Renderer {
        let u = wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST;
        let vertices = buffer(gpu, "vertices", bytemuck::cast_slice(&scene.vertices), u);
        let cverts = buffer(gpu, "cluster verts", bytemuck::cast_slice(&scene.cluster_verts), u);
        let tris = buffer(gpu, "tris", bytemuck::cast_slice(&scene.tris), u);
        let clusters = buffer(gpu, "clusters", bytemuck::cast_slice(&scene.clusters), u);
        let instances = buffer(gpu, "instances", bytemuck::cast_slice(&scene.instances), u);
        let materials = buffer(gpu, "materials", bytemuck::cast_slice(&scene.materials), u);
        let aux = buffer(gpu, "aux", bytemuck::cast_slice(&scene.aux), u);
        let albedo = texture_array(gpu, scene, 1024);
        let albedo_view = albedo.create_view(&wgpu::TextureViewDescriptor { dimension: Some(wgpu::TextureViewDimension::D2Array), ..Default::default() });
        let samp = gpu.device.create_sampler(&wgpu::SamplerDescriptor {
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        });
        let tex_array = wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2Array, multisampled: false };
        let scene_layout = layout(
            gpu,
            "scene",
            &[
                (0, storage(true)),
                (1, storage(true)),
                (2, storage(true)),
                (3, storage(true)),
                (4, storage(true)),
                (5, storage(true)),
                (6, tex_array),
                (7, wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering)),
                (8, storage(true)),
            ],
        );
        let scene_bind = bind(
            gpu,
            &scene_layout,
            &[
                (0, vertices.as_entire_binding()),
                (1, cverts.as_entire_binding()),
                (2, tris.as_entire_binding()),
                (3, clusters.as_entire_binding()),
                (4, instances.as_entire_binding()),
                (5, materials.as_entire_binding()),
                (6, wgpu::BindingResource::TextureView(&albedo_view)),
                (7, wgpu::BindingResource::Sampler(&samp)),
                (8, aux.as_entire_binding()),
            ],
        );
        let view_cull_layout = layout(gpu, "view cull", &[(0, uniform()), (1, storage(false)), (2, storage(false)), (3, storage(false))]);
        let view_raster_layout = layout(gpu, "view raster", &[(0, uniform()), (1, storage(true))]);
        let shade_layout = layout(
            gpu,
            "shade",
            &[
                (0, uniform()),
                (1, storage(true)),
                (2, uniform()),
                (3, wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Uint, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }),
                (4, wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Depth, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }),
                (5, wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Depth, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }),
                (6, wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Comparison)),
                (7, wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: false }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }),
                (8, wgpu::BindingType::StorageTexture { access: wgpu::StorageTextureAccess::WriteOnly, format: wgpu::TextureFormat::Rgba16Float, view_dimension: wgpu::TextureViewDimension::D2 }),
            ],
        );
        let tone_layout = layout(
            gpu,
            "tone",
            &[
                (0, wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: false }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }),
                (1, wgpu::BindingType::StorageTexture { access: wgpu::StorageTextureAccess::WriteOnly, format: wgpu::TextureFormat::Rgba8Unorm, view_dimension: wgpu::TextureViewDimension::D2 }),
                (2, uniform()),
            ],
        );
        let module = |name: &str, src: &str| gpu.device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some(name), source: wgpu::ShaderSource::Wgsl(src.into()) });
        let cull_mod = module("cull", include_str!("shaders/cull.wgsl"));
        let raster_mod = module("raster", include_str!("shaders/raster.wgsl"));
        let shade_mod = module("shade", include_str!("shaders/shade.wgsl"));
        let tone_mod = module("tonemap", include_str!("shaders/tonemap.wgsl"));
        let pl = |layouts: &[&wgpu::BindGroupLayout]| {
            let l: Vec<Option<&wgpu::BindGroupLayout>> = layouts.iter().map(|x| Some(*x)).collect();
            gpu.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &l, immediate_size: 0 })
        };
        let compute = |layout: &wgpu::PipelineLayout, m: &wgpu::ShaderModule, entry: &str| {
            gpu.device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(layout),
                module: m,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        };
        let cull_pl = pl(&[&scene_layout, &view_cull_layout]);
        let cull = compute(&cull_pl, &cull_mod, "cull");
        let finalize = compute(&cull_pl, &cull_mod, "finalize");
        let raster_pl = pl(&[&scene_layout, &view_raster_layout]);
        let raster_pipe = |color: bool| {
            let targets = [Some(wgpu::ColorTargetState { format: wgpu::TextureFormat::R32Uint, blend: None, write_mask: wgpu::ColorWrites::ALL })];
            gpu.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(if color { "raster" } else { "raster depth" }),
                layout: Some(&raster_pl),
                vertex: wgpu::VertexState { module: &raster_mod, entry_point: Some("vs"), compilation_options: Default::default(), buffers: &[] },
                primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleList, cull_mode: None, ..Default::default() },
                depth_stencil: Some(wgpu::DepthStencilState {
                    format: wgpu::TextureFormat::Depth32Float,
                    depth_write_enabled: Some(true),
                    // Main view: reversed Z (1 near, 0 at infinity). Shadow: ordinary.
                    depth_compare: Some(if color { wgpu::CompareFunction::Greater } else { wgpu::CompareFunction::Less }),
                    stencil: Default::default(),
                    bias: if color { Default::default() } else { wgpu::DepthBiasState { constant: 2, slope_scale: 2.0, clamp: 0.0 } },
                }),
                multisample: Default::default(),
                fragment: Some(wgpu::FragmentState {
                    module: &raster_mod,
                    entry_point: Some(if color { "fs" } else { "fs_depth" }),
                    compilation_options: Default::default(),
                    targets: if color { &targets } else { &[] },
                }),
                multiview_mask: None,
                cache: None,
            })
        };
        let raster = raster_pipe(true);
        let raster_depth = raster_pipe(false);
        let shade = compute(&pl(&[&scene_layout, &shade_layout]), &shade_mod, "shade");
        let tone = compute(&pl(&[&tone_layout]), &tone_mod, "main");

        // Sky: turn the HDRI so its sun sits where our sun is, scale it so
        // its diffuse light matches `sky_lux`.
        let (sw, shh, spx) = scene.sky.clone().unwrap_or((2, 1, vec![[0.5, 0.6, 0.8, 1.0]; 2]));
        let (mut bx, mut by, mut bv) = (0, 0, 0.0f32);
        for y in 0..shh / 2 {
            for x in 0..sw {
                let c = spx[(y * sw + x) as usize];
                let l = c[0] + c[1] + c[2];
                if l > bv {
                    (bx, by, bv) = (x, y, l);
                }
            }
        }
        let hdri_az = ((bx as f32 + 0.5) / sw as f32 - 0.5) * 2.0 * PI;
        let our_az = light.sun_dir.x.atan2(-light.sun_dir.z);
        let rotation = hdri_az - our_az;
        let _ = by;
        let mean: f32 = spx.iter().map(|c| c[0] + c[1] + c[2]).sum::<f32>() / (spx.len() as f32 * 3.0);
        let (raw_sh, raw_horizon) = sky_sh(sw, shh, &spx, rotation, mean * 8.0);
        let up = eval_irradiance_up(&raw_sh).max(1e-6);
        let sky_scale = light.sky_lux / up;
        let mut sky_sh = raw_sh;
        for c in sky_sh.iter_mut() {
            for k in 0..3 {
                c[k] *= sky_scale;
            }
        }
        let sky_tex = gpu.device.create_texture_with_data(
            &gpu.queue,
            &wgpu::TextureDescriptor {
                label: Some("sky"),
                size: wgpu::Extent3d { width: sw, height: shh, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba32Float,
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
            Default::default(),
            bytemuck::cast_slice(&spx),
        );
        let shadow_samp = gpu.device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            compare: Some(wgpu::CompareFunction::LessEqual),
            ..Default::default()
        });
        let query = if gpu.features.contains(wgpu::Features::TIMESTAMP_QUERY) {
            let n = 16;
            let qs = gpu.device.create_query_set(&wgpu::QuerySetDescriptor { label: Some("timestamps"), ty: wgpu::QueryType::Timestamp, count: n });
            let resolve = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: 8 * n as u64, usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC, mapped_at_creation: false });
            let read = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: 8 * n as u64, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
            Some((qs, resolve, read))
        } else {
            None
        };
        Renderer {
            scene_bind,
            cull,
            finalize,
            raster,
            raster_depth,
            shade,
            tone,
            shade_layout,
            tone_layout,
            view_cull_layout,
            view_raster_layout,
            instances: scene.instances.len() as u32,
            sky_view: sky_tex.create_view(&Default::default()),
            sky_sh,
            sky_horizon: raw_horizon * sky_scale,
            sky_scale,
            sky_rotation: rotation,
            shadow_samp,
            query,
        }
    }

    fn view_targets(&self, gpu: &Gpu, label: &str) -> ViewTargets {
        let uniform = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: Some(label), size: std::mem::size_of::<ViewUniform>() as u64, usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
        let visible = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: Some("visible"), size: MAX_VISIBLE as u64 * 8, usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC, mapped_at_creation: false });
        let counter = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: Some("counter"), size: 16, usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC, mapped_at_creation: false });
        let args = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: Some("args"), size: 16, usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::INDIRECT, mapped_at_creation: false });
        let cull_bind = bind(gpu, &self.view_cull_layout, &[(0, uniform.as_entire_binding()), (1, visible.as_entire_binding()), (2, counter.as_entire_binding()), (3, args.as_entire_binding())]);
        let raster_bind = bind(gpu, &self.view_raster_layout, &[(0, uniform.as_entire_binding()), (1, visible.as_entire_binding())]);
        ViewTargets { uniform, visible, counter, args, cull_bind, raster_bind }
    }

    fn cull_and_raster(&self, enc: &mut wgpu::CommandEncoder, gpu: &Gpu, v: &ViewTargets, color: Option<&wgpu::TextureView>, depth: &wgpu::TextureView, ts: &mut u32, names: &mut Vec<&'static str>, name: &'static str) {
        gpu.queue.write_buffer(&v.counter, 0, &[0u8; 16]);
        let tw = |ts: &mut u32| {
            self.query.as_ref().map(|(qs, _, _)| {
                let i = *ts;
                *ts += 2;
                (qs, i)
            })
        };
        {
            let t = tw(ts);
            if t.is_some() {
                names.push(name);
            }
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("cull"),
                timestamp_writes: t.map(|(qs, i)| wgpu::ComputePassTimestampWrites { query_set: qs, beginning_of_pass_write_index: Some(i), end_of_pass_write_index: Some(i + 1) }),
            });
            pass.set_pipeline(&self.cull);
            pass.set_bind_group(0, &self.scene_bind, &[]);
            pass.set_bind_group(1, &v.cull_bind, &[]);
            let n = self.instances;
            pass.dispatch_workgroups(n.min(65535), n.div_ceil(65535), 1);
            pass.set_pipeline(&self.finalize);
            pass.dispatch_workgroups(1, 1, 1);
        }
        let t = tw(ts);
        if t.is_some() {
            names.push(if color.is_some() { "raster" } else { "shadow raster" });
        }
        let attachments = [color.map(|c| wgpu::RenderPassColorAttachment {
            view: c,
            depth_slice: None,
            resolve_target: None,
            // Empty pixels read as u32::MAX.
            ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r: u32::MAX as f64, g: 0.0, b: 0.0, a: 0.0 }), store: wgpu::StoreOp::Store },
        })];
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("raster"),
            color_attachments: if color.is_some() { &attachments } else { &[] },
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: depth,
                depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(if color.is_some() { 0.0 } else { 1.0 }), store: wgpu::StoreOp::Store }),
                stencil_ops: None,
            }),
            timestamp_writes: t.map(|(qs, i)| wgpu::RenderPassTimestampWrites { query_set: qs, beginning_of_pass_write_index: Some(i), end_of_pass_write_index: Some(i + 1) }),
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(if color.is_some() { &self.raster } else { &self.raster_depth });
        pass.set_bind_group(0, &self.scene_bind, &[]);
        pass.set_bind_group(1, &v.raster_bind, &[]);
        pass.draw_indirect(&v.args, 0);
    }

    /// Render one view to an RGBA8 image.
    pub fn render(&self, gpu: &Gpu, cam: &Camera, light: &Lighting, w: u32, h: u32) -> (Vec<u8>, FrameStats) {
        self.render_picking(gpu, cam, light, w, h, &[])
    }

    /// Render, and report what covers each of `picks` (pixel coordinates).
    pub fn render_picking(&self, gpu: &Gpu, cam: &Camera, light: &Lighting, w: u32, h: u32, picks: &[(u32, u32)]) -> (Vec<u8>, FrameStats) {
        let tex = |label: &str, format, usage| {
            gpu.device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage,
                view_formats: &[],
            })
        };
        let rt = wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC;
        let vis = tex("vis", wgpu::TextureFormat::R32Uint, rt);
        let depth = tex("depth", wgpu::TextureFormat::Depth32Float, rt);
        let hdr = tex("hdr", wgpu::TextureFormat::Rgba16Float, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::TEXTURE_BINDING);
        let ldr = tex("ldr", wgpu::TextureFormat::Rgba8Unorm, wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC);
        let shadow = gpu.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("shadow"),
            size: wgpu::Extent3d { width: SHADOW_SIZE, height: SHADOW_SIZE, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: rt,
            view_formats: &[],
        });
        let (vis_v, depth_v, hdr_v, ldr_v, shadow_v) = (vis.create_view(&Default::default()), depth.create_view(&Default::default()), hdr.create_view(&Default::default()), ldr.create_view(&Default::default()), shadow.create_view(&Default::default()));

        // Main view: reversed-Z infinite perspective.
        let aspect = w as f32 / h as f32;
        let view_m = Mat4::look_at_rh(cam.pos, cam.target, Vec3::Y);
        let proj = Mat4::perspective_infinite_reverse_rh(cam.fov_y, aspect, cam.near);
        let vp = proj * view_m;
        let main = self.view_targets(gpu, "main view");
        let px_scale = proj.y_axis.y * 0.5 * h as f32;
        gpu.queue.write_buffer(&main.uniform, 0, bytemuck::bytes_of(&view_uniform(vp, cam.pos, px_scale, [light.lod_pixels, cam.near, 0.0, MAX_VISIBLE as f32], [w as f32, h as f32, 1.0 / w as f32, 1.0 / h as f32])));

        // Sun shadow: an orthographic box around what the camera looks at.
        let extent = 90.0f32;
        let fwd = (cam.target - cam.pos).normalize_or(Vec3::NEG_Z);
        let centre = cam.pos + Vec3::new(fwd.x, 0.0, fwd.z).normalize_or_zero() * (extent * 0.6);
        let texel = 2.0 * extent / SHADOW_SIZE as f32;
        let sun_view = Mat4::look_at_rh(centre + light.sun_dir * 400.0, centre, Vec3::Y);
        // Snap to whole texels so the shadow does not crawl as the camera moves.
        let c_ls = sun_view.transform_point3(centre);
        let snap = Vec3::new((c_ls.x / texel).round() * texel - c_ls.x, (c_ls.y / texel).round() * texel - c_ls.y, 0.0);
        let sun_view = Mat4::from_translation(snap) * sun_view;
        let sun_proj = Mat4::orthographic_rh(-extent, extent, -extent, extent, 1.0, 900.0);
        let svp = sun_proj * sun_view;
        let shadow_t = self.view_targets(gpu, "sun view");
        gpu.queue.write_buffer(
            &shadow_t.uniform,
            0,
            bytemuck::bytes_of(&view_uniform(svp, centre + light.sun_dir * 400.0, SHADOW_SIZE as f32 / (2.0 * extent), [light.lod_pixels * 2.0, 1.0, 1.0, MAX_VISIBLE as f32], [SHADOW_SIZE as f32; 4])),
        );

        let mut sh = self.sky_sh;
        sh.iter_mut().for_each(|c| c[3] = 0.0);
        let lu = LightUniform {
            sun_dir: [light.sun_dir.x, light.sun_dir.y, light.sun_dir.z, light.sun_lux],
            sun_color: [light.sun_color.x, light.sun_color.y, light.sun_color.z, light.shadow_strength],
            shadow_view_proj: svp.to_cols_array_2d(),
            sky: [self.sky_scale, self.sky_rotation, 0.0, texel],
            fog_color: [self.sky_horizon.x, self.sky_horizon.y, self.sky_horizon.z, light.fog_start],
            fog: [light.fog_end, light.fog_density, 0.0, 0.0],
            sh,
        };
        let light_buf = buffer(gpu, "light", bytemuck::bytes_of(&lu), wgpu::BufferUsages::UNIFORM);
        let exposure = 1.0 / (1.2 * 2f32.powf(light.ev100));
        let tone_buf = buffer(gpu, "tone", bytemuck::bytes_of(&ToneUniform { exposure, contrast: light.contrast, saturation: light.saturation, pad: 0.0 }), wgpu::BufferUsages::UNIFORM);

        let shade_bind = bind(
            gpu,
            &self.shade_layout,
            &[
                (0, main.uniform.as_entire_binding()),
                (1, main.visible.as_entire_binding()),
                (2, light_buf.as_entire_binding()),
                (3, wgpu::BindingResource::TextureView(&vis_v)),
                (4, wgpu::BindingResource::TextureView(&depth_v)),
                (5, wgpu::BindingResource::TextureView(&shadow_v)),
                (6, wgpu::BindingResource::Sampler(&self.shadow_samp)),
                (7, wgpu::BindingResource::TextureView(&self.sky_view)),
                (8, wgpu::BindingResource::TextureView(&hdr_v)),
            ],
        );
        let tone_bind = bind(gpu, &self.tone_layout, &[(0, wgpu::BindingResource::TextureView(&hdr_v)), (1, wgpu::BindingResource::TextureView(&ldr_v)), (2, tone_buf.as_entire_binding())]);

        let mut enc = gpu.device.create_command_encoder(&Default::default());
        let mut ts = 0u32;
        let mut names = Vec::new();
        self.cull_and_raster(&mut enc, gpu, &shadow_t, None, &shadow_v, &mut ts, &mut names, "shadow cull");
        self.cull_and_raster(&mut enc, gpu, &main, Some(&vis_v), &depth_v, &mut ts, &mut names, "cull");
        for (label, pipe, bindings, wg) in [("shade", &self.shade, vec![&self.scene_bind, &shade_bind], (w.div_ceil(8), h.div_ceil(8))), ("tonemap", &self.tone, vec![&tone_bind], (w.div_ceil(8), h.div_ceil(8)))] {
            let t = self.query.as_ref().map(|(qs, _, _)| {
                let i = ts;
                ts += 2;
                (qs, i)
            });
            if t.is_some() {
                names.push(label);
            }
            let mut pass = enc.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some(label),
                timestamp_writes: t.map(|(qs, i)| wgpu::ComputePassTimestampWrites { query_set: qs, beginning_of_pass_write_index: Some(i), end_of_pass_write_index: Some(i + 1) }),
            });
            pass.set_pipeline(pipe);
            for (k, b) in bindings.iter().enumerate() {
                pass.set_bind_group(k as u32, *b, &[]);
            }
            pass.dispatch_workgroups(wg.0, wg.1, 1);
        }
        let counters = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: 32, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
        enc.copy_buffer_to_buffer(&main.counter, 0, &counters, 0, 16);
        enc.copy_buffer_to_buffer(&shadow_t.counter, 0, &counters, 16, 16);
        if let Some((qs, resolve, read)) = &self.query {
            enc.resolve_query_set(qs, 0..ts, resolve, 0);
            enc.copy_buffer_to_buffer(resolve, 0, read, 0, 8 * ts as u64);
        }
        gpu.queue.submit([enc.finish()]);
        let pixels = gpu.read_rgba8(&ldr);
        let mut stats = FrameStats::default();
        if !picks.is_empty() {
            // The visibility buffer is 4 bytes per pixel too.
            let ids = gpu.read_rgba8(&vis);
            let vis_list = gpu.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: MAX_VISIBLE as u64 * 8, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
            let mut enc = gpu.device.create_command_encoder(&Default::default());
            enc.copy_buffer_to_buffer(&main.visible, 0, &vis_list, 0, MAX_VISIBLE as u64 * 8);
            gpu.queue.submit([enc.finish()]);
            vis_list.slice(..).map_async(wgpu::MapMode::Read, |_| {});
            gpu.wait();
            let list = vis_list.slice(..).get_mapped_range().expect("visible list");
            let list: &[u32] = bytemuck::cast_slice(&list);
            for &(x, y) in picks {
                let k = ((y * w + x) * 4) as usize;
                let id = u32::from_le_bytes(ids[k..k + 4].try_into().unwrap());
                stats.picks.push(if id == u32::MAX { None } else { Some((list[(id >> 7) as usize * 2], list[(id >> 7) as usize * 2 + 1], id & 127)) });
            }
        }
        counters.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        if let Some((_, _, read)) = &self.query {
            read.slice(..).map_async(wgpu::MapMode::Read, |_| {});
        }
        gpu.wait();
        {
            let c = counters.slice(..).get_mapped_range().expect("counters");
            let c: &[u32] = bytemuck::cast_slice(&c);
            stats.clusters = c[0];
            stats.triangles = c[1];
            stats.shadow_clusters = c[4];
            stats.shadow_triangles = c[5];
        }
        if let Some((_, _, read)) = &self.query {
            {
                let t = read.slice(..).get_mapped_range().expect("timestamps");
                let t: &[u64] = bytemuck::cast_slice(&t);
                let period = gpu.queue.get_timestamp_period() as f64;
                for (k, name) in names.iter().enumerate() {
                    let (a, b) = (t[2 * k], t[2 * k + 1]);
                    stats.gpu_ms.push((name, b.saturating_sub(a) as f64 * period / 1e6));
                }
            }
            read.unmap();
        }
        (pixels, stats)
    }
}

fn view_uniform(vp: Mat4, cam: Vec3, px_scale: f32, params: [f32; 4], size: [f32; 4]) -> ViewUniform {
    // Frustum planes from the view-projection (Gribb-Hartmann), normalised.
    // Reversed/infinite depth: skip the far plane (keep it permissive).
    let m = vp.transpose();
    let rows = [m.x_axis, m.y_axis, m.z_axis, m.w_axis];
    let mut planes = [[0.0f32; 4]; 6];
    let raw: [Vec4; 6] = [rows[3] + rows[0], rows[3] - rows[0], rows[3] + rows[1], rows[3] - rows[1], rows[2], rows[3] - rows[2]];
    for (k, p) in raw.iter().enumerate() {
        let n = p.truncate().length();
        planes[k] = if n > 1e-6 { (*p / n).to_array() } else { [0.0, 0.0, 0.0, 1.0] };
    }
    // For reversed-Z the "far" plane (index 5) is z <= w at the near plane;
    // for orthographic shadows both depth planes are real. Planes stay as
    // computed: both cases keep geometry in [0, 1] depth.
    ViewUniform {
        view_proj: vp.to_cols_array_2d(),
        inv_view_proj: vp.inverse().to_cols_array_2d(),
        cam: [cam.x, cam.y, cam.z, px_scale],
        planes,
        params,
        size,
    }
}
