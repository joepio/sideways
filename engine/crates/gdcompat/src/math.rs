//! Godot's float vectors: components are f32, every operation rounds to f32,
//! exactly as Vector2/Vector3 do in C++. GDScript's own `float` is f64, so a
//! port keeps scalars in f64 and converts where Godot stores into a vector or
//! a Packed*Array.

use std::ops::{Add, AddAssign, Mul, Neg, Sub, SubAssign};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V2 {
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

pub const fn v2(x: f32, y: f32) -> V2 {
    V2 { x, y }
}

pub const fn v3(x: f32, y: f32, z: f32) -> V3 {
    V3 { x, y, z }
}

impl V2 {
    pub fn length_squared(self) -> f32 {
        self.x * self.x + self.y * self.y
    }
    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }
    pub fn normalized(self) -> V2 {
        let l = self.length_squared();
        if l == 0.0 {
            return V2::default();
        }
        let l = l.sqrt();
        v2(self.x / l, self.y / l)
    }
    pub fn dot(self, o: V2) -> f32 {
        self.x * o.x + self.y * o.y
    }
    pub fn distance_squared_to(self, o: V2) -> f32 {
        (self - o).length_squared()
    }
    pub fn distance_to(self, o: V2) -> f32 {
        (self - o).length()
    }
    pub fn lerp(self, o: V2, t: f32) -> V2 {
        v2(self.x + t * (o.x - self.x), self.y + t * (o.y - self.y))
    }
    /// `Vector2.angle()`: atan2(y, x) in f32.
    pub fn angle(self) -> f32 {
        self.y.atan2(self.x)
    }
}

impl V3 {
    pub const ZERO: V3 = v3(0.0, 0.0, 0.0);
    pub const UP: V3 = v3(0.0, 1.0, 0.0);

    pub fn length_squared(self) -> f32 {
        self.x * self.x + self.y * self.y + self.z * self.z
    }
    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }
    pub fn normalized(self) -> V3 {
        let l = self.length_squared();
        if l == 0.0 {
            return V3::ZERO;
        }
        let l = l.sqrt();
        v3(self.x / l, self.y / l, self.z / l)
    }
    pub fn dot(self, o: V3) -> f32 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }
    pub fn cross(self, o: V3) -> V3 {
        v3(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )
    }
    pub fn lerp(self, o: V3, t: f32) -> V3 {
        v3(
            self.x + t * (o.x - self.x),
            self.y + t * (o.y - self.y),
            self.z + t * (o.z - self.z),
        )
    }
    pub fn xz(self) -> V2 {
        v2(self.x, self.z)
    }
}

macro_rules! ops {
    ($t:ident, $($f:ident),+) => {
        impl Add for $t { type Output = $t; fn add(self, o: $t) -> $t { $t { $($f: self.$f + o.$f),+ } } }
        impl Sub for $t { type Output = $t; fn sub(self, o: $t) -> $t { $t { $($f: self.$f - o.$f),+ } } }
        impl Mul<f32> for $t { type Output = $t; fn mul(self, s: f32) -> $t { $t { $($f: self.$f * s),+ } } }
        impl Neg for $t { type Output = $t; fn neg(self) -> $t { $t { $($f: -self.$f),+ } } }
        impl AddAssign for $t { fn add_assign(&mut self, o: $t) { $(self.$f += o.$f;)+ } }
        impl SubAssign for $t { fn sub_assign(&mut self, o: $t) { $(self.$f -= o.$f;)+ } }
    };
}
ops!(V2, x, y);
ops!(V3, x, y, z);

/// GDScript `smoothstep(from, to, x)` (doubles).
pub fn smoothstep(from: f64, to: f64, x: f64) -> f64 {
    if from == to {
        return if x < from { 0.0 } else { 1.0 };
    }
    let s = ((x - from) / (to - from)).clamp(0.0, 1.0);
    s * s * (3.0 - 2.0 * s)
}

pub fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

pub fn move_toward(from: f64, to: f64, delta: f64) -> f64 {
    if (to - from).abs() <= delta {
        to
    } else {
        from + (to - from).signum() * delta
    }
}

/// GDScript `signf`: 0 for 0.
pub fn signf(x: f64) -> f64 {
    if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    }
}

pub fn fposmod(x: f64, y: f64) -> f64 {
    let mut v = x % y;
    if (v < 0.0 && y > 0.0) || (v > 0.0 && y < 0.0) {
        v += y;
    }
    v
}
