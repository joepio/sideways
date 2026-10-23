//! The physics world: Rapier, with the stage's colliders and the cars'
//! bodies. A collider's user_data is the surface the tyres find on it, or
//! ROAD for the road ribbon (whose surface comes from the stage layout).

use crate::builder::{self, Block, Chunk, Road};
use crate::spec::CarSpec;
use crate::surfaces::Surface;
use gdcompat::math::V3;
use rapier3d::glamx::{Pose3, Quat, Vec3};
use rapier3d::parry::shape::TriMeshFlags;
use rapier3d::prelude::*;

pub const ROAD: u128 = 255;
pub const GROUP_WORLD: Group = Group::GROUP_1;
pub const GROUP_CAR: Group = Group::GROUP_2;
pub const GROUP_GHOST: Group = Group::GROUP_3;
pub const HZ: f64 = 120.0;

pub struct Physics {
    pub world: PhysicsWorld,
}

fn g(v: V3) -> Vec3 {
    Vec3::new(v.x, v.y, v.z)
}

impl Physics {
    pub fn new() -> Physics {
        let mut world = PhysicsWorld::default();
        world.gravity = Vec3::new(0.0, -9.8, 0.0); // Godot's default
        world.integration_parameters.dt = (1.0 / HZ) as f32;
        Physics { world }
    }

    fn world_groups() -> InteractionGroups {
        InteractionGroups::new(GROUP_WORLD, Group::ALL, InteractionTestMode::And)
    }

    /// Godot winds its ground triangles facing down (its concave shapes
    /// are double-sided); Rapier's are one-sided with internal-edge fixing,
    /// so the winding is flipped here to face up.
    pub fn add_trimesh(&mut self, verts: Vec<Vec3>, tris: Vec<[u32; 3]>, tag: u128) {
        let tris: Vec<[u32; 3]> = tris.into_iter().map(|[a, b, c]| [a, c, b]).collect();
        let c = ColliderBuilder::trimesh_with_flags(verts, tris, TriMeshFlags::FIX_INTERNAL_EDGES)
            .expect("trimesh")
            .user_data(tag)
            .collision_groups(Self::world_groups())
            .build();
        self.world.colliders.insert(c);
    }

    pub fn add_chunk(&mut self, c: &Chunk) {
        let (verts, tris) = c.triangles();
        self.add_trimesh(verts.into_iter().map(g).collect(), tris, Surface::Grass as u128);
    }

    pub fn add_road(&mut self, r: &Road) {
        self.add_trimesh(r.verts.iter().map(|v| g(*v)).collect(), r.tris.clone(), ROAD);
    }

    /// A tree trunk: the 12-sided prism (radius 0.22, -0.5..5.5 m) as a cylinder.
    pub fn add_trunk(&mut self, t: &builder::Spot) {
        let half = 3.0 * t.scale_y;
        let c = ColliderBuilder::cylinder(half, 0.22 * t.scale)
            .translation(Vec3::new(t.pos.0, t.pos.1 + 2.5 * t.scale_y, t.pos.2))
            .user_data(Surface::Dirt as u128)
            .collision_groups(Self::world_groups())
            .build();
        self.world.colliders.insert(c);
    }

    pub fn add_block(&mut self, b: &Block) {
        // Godot's looking_at: local -Z along the direction.
        let rot = Quat::from_rotation_arc(Vec3::NEG_Z, g(b.along).normalize_or(Vec3::NEG_Z));
        let c = ColliderBuilder::cuboid(b.half.x, b.half.y, b.half.z)
            .position(Pose3::from_parts(g(b.centre), rot))
            .user_data(Surface::Dirt as u128)
            .collision_groups(Self::world_groups())
            .build();
        self.world.colliders.insert(c);
    }

    /// Flat bench ground at y = 0. A half-space, not Godot's 6 km box:
    /// GJK loses f32 precision against support points that far out.
    pub fn add_flat_ground(&mut self, surface: Surface) {
        let c = ColliderBuilder::new(SharedShape::halfspace(Vec3::Y))
            .user_data(surface as u128)
            .collision_groups(Self::world_groups())
            .build();
        self.world.colliders.insert(c);
    }

    /// A car body: mass, inertia and centre of mass from the spec, boxes
    /// for collision. `contact` lets it hit other cars.
    pub fn add_car(&mut self, spec: &CarSpec, pose: Pose3, contact: bool) -> RigidBodyHandle {
        let mp = MassProperties::new(
            Vec3::new(spec.cg[0] as f32, spec.cg[1] as f32, spec.cg[2] as f32),
            spec.mass as f32,
            Vec3::new(spec.inertia[0] as f32, spec.inertia[1] as f32, spec.inertia[2] as f32),
        );
        let rb = RigidBodyBuilder::dynamic()
            .pose(pose)
            .additional_mass_properties(mp)
            .angular_damping(0.05)
            .linear_damping(0.0)
            .can_sleep(false)
            .ccd_enabled(true)
            .build();
        let h = self.world.bodies.insert(rb);
        for b in &spec.boxes {
            let c = ColliderBuilder::cuboid(b[0] as f32 * 0.5, b[1] as f32 * 0.5, b[2] as f32 * 0.5)
                .translation(Vec3::new(b[3] as f32, b[4] as f32, b[5] as f32))
                .density(0.0)
                .friction(0.45)
                .friction_combine_rule(CoefficientCombineRule::Min)
                .restitution(0.05)
                .collision_groups(car_groups(contact))
                .build();
            self.world.colliders.insert_with_parent(c, h, &mut self.world.bodies);
        }
        h
    }

    pub fn set_car_contact(&mut self, body: RigidBodyHandle, contact: bool) {
        let colliders: Vec<_> = self.world.bodies[body].colliders().to_vec();
        for c in colliders {
            self.world.colliders[c].set_collision_groups(car_groups(contact));
        }
    }

    pub fn step(&mut self) {
        self.world.step();
    }
}

impl Default for Physics {
    fn default() -> Self {
        Physics::new()
    }
}

/// Cars collide with the world, and with each other unless ghosted.
fn car_groups(contact: bool) -> InteractionGroups {
    if contact {
        InteractionGroups::new(GROUP_CAR, GROUP_WORLD | GROUP_CAR, InteractionTestMode::And)
    } else {
        InteractionGroups::new(GROUP_GHOST, GROUP_WORLD, InteractionTestMode::And)
    }
}
