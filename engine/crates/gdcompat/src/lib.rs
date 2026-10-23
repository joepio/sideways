//! Bit-exact pieces of Godot 4 for porting a Godot game: the PCG32 random
//! number generator behind `seed()`, `randi()`, `randf()` and
//! `RandomNumberGenerator`; `hash()` for ints, strings and arrays; and
//! `FastNoiseLite` with Godot's defaults. Checked against Godot 4.5 by the
//! oracle (tools/oracle_dump.gd, `sideways check`).

pub mod math;

/// Godot's `RandomPCG` (core/math/random_pcg.h).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pcg {
    state: u64,
    inc: u64,
}

pub const DEFAULT_SEED: u64 = 12047754176567800795;
pub const DEFAULT_INC: u64 = 1442695040888963407;

impl Default for Pcg {
    fn default() -> Self {
        Pcg::new(DEFAULT_SEED)
    }
}

impl Pcg {
    pub fn new(seed: u64) -> Pcg {
        let mut p = Pcg { state: 0, inc: 0 };
        p.seed(seed);
        p
    }

    /// `seed(s)` / `rng.seed = s`.
    pub fn seed(&mut self, seed: u64) {
        self.state = 0;
        self.inc = (DEFAULT_INC << 1) | 1;
        self.next_u32();
        self.state = self.state.wrapping_add(seed);
        self.next_u32();
    }

    /// `randi()`.
    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(6364136223846793005).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    fn bounded(&mut self, bound: u32) -> u32 {
        if bound == 0 {
            return 0;
        }
        let threshold = bound.wrapping_neg() % bound;
        loop {
            let r = self.next_u32();
            if r >= threshold {
                return r % bound;
            }
        }
    }

    /// The global `randf()`: one draw divided by 2^32, in f32.
    pub fn randf_global(&mut self) -> f32 {
        self.next_u32() as f32 / 4294967296.0
    }

    /// `RandomNumberGenerator.randf()`: a float in [0, 1].
    pub fn randf(&mut self) -> f32 {
        let proto = self.next_u32();
        if proto == 0 {
            return 0.0;
        }
        let m = (self.next_u32() | 0x8000_0001) as f32;
        ldexpf(m, -32 - proto.leading_zeros() as i32)
    }

    /// The double version behind the global `randf_range()`.
    pub fn randd(&mut self) -> f64 {
        let proto = self.next_u32();
        if proto == 0 {
            return 0.0;
        }
        let hi = self.next_u32() as u64;
        let lo = self.next_u32() as u64;
        let significand = (hi << 32) | lo | 0x8000_0000_0000_0001;
        ldexp(significand as f64, -64 - proto.leading_zeros() as i32)
    }

    /// Global `randf_range(a, b)` (doubles).
    pub fn randf_range(&mut self, from: f64, to: f64) -> f64 {
        self.randd() * (to - from) + from
    }

    /// `RandomNumberGenerator.randf_range(a, b)` (floats).
    pub fn randf_range_f32(&mut self, from: f32, to: f32) -> f32 {
        self.randf() * (to - from) + from
    }

    /// `randi_range(a, b)`, both ends included.
    pub fn randi_range(&mut self, from: i32, to: i32) -> i32 {
        if from == to {
            return from;
        }
        self.bounded((from.wrapping_sub(to)).unsigned_abs() + 1) as i32 + from.min(to)
    }
}

fn ldexpf(x: f32, e: i32) -> f32 {
    // Exact for the ranges used here: scaling by a power of two.
    (x as f64 * 2f64.powi(e)) as f32
}

fn ldexp(x: f64, e: i32) -> f64 {
    x * 2f64.powi(e)
}

/// A value Godot's `hash()` can take.
#[derive(Clone, Debug)]
pub enum Var<'a> {
    Int(i64),
    Str(&'a str),
    Array(&'a [Var<'a>]),
}

const VARIANT_ARRAY: u32 = 28;
const MURMUR3_SEED: u32 = 0x7F07C65;

pub fn hash_one_u64(v: u64) -> u32 {
    let mut v = v;
    v = (!v).wrapping_add(v << 18);
    v ^= v >> 31;
    v = v.wrapping_mul(21);
    v ^= v >> 11;
    v = v.wrapping_add(v << 6);
    v ^= v >> 22;
    v as u32
}

fn murmur3_one_32(input: u32, seed: u32) -> u32 {
    let mut k = input.wrapping_mul(0xcc9e2d51);
    k = k.rotate_left(15);
    k = k.wrapping_mul(0x1b873593);
    let mut h = seed ^ k;
    h = h.rotate_left(13);
    h.wrapping_mul(5).wrapping_add(0xe6546b64)
}

fn fmix32(mut h: u32) -> u32 {
    h ^= h >> 16;
    h = h.wrapping_mul(0x85ebca6b);
    h ^= h >> 13;
    h = h.wrapping_mul(0xc2b2ae35);
    h ^= h >> 16;
    h
}

/// Godot's `hash(value)`.
pub fn hash(v: &Var) -> u32 {
    match v {
        Var::Int(i) => hash_one_u64(*i as u64),
        Var::Str(s) => {
            let mut h: u32 = 5381;
            for c in s.chars() {
                h = (h << 5).wrapping_add(h).wrapping_add(c as u32);
            }
            h
        }
        Var::Array(items) => {
            let mut h = murmur3_one_32(VARIANT_ARRAY, MURMUR3_SEED);
            for it in items.iter() {
                h = murmur3_one_32(hash(it), h);
            }
            fmix32(h)
        }
    }
}

/// `FastNoiseLite` as Godot sets it up: OpenSimplex2S ("simplex smooth"),
/// FBm with lacunarity 2 and gain 0.5.
pub struct Noise {
    inner: fastnoise_lite::FastNoiseLite,
}

impl Noise {
    pub fn new(seed: i32, frequency: f32, octaves: i32) -> Noise {
        let mut n = fastnoise_lite::FastNoiseLite::with_seed(seed);
        n.set_noise_type(Some(fastnoise_lite::NoiseType::OpenSimplex2S));
        n.set_frequency(Some(frequency));
        n.set_fractal_type(Some(fastnoise_lite::FractalType::FBm));
        n.set_fractal_octaves(Some(octaves));
        n.set_fractal_lacunarity(Some(2.0));
        n.set_fractal_gain(Some(0.5));
        Noise { inner: n }
    }

    /// Godot's default octave count is 5.
    pub fn with_defaults(seed: i32, frequency: f32) -> Noise {
        Noise::new(seed, frequency, 5)
    }

    pub fn get_2d(&self, x: f32, y: f32) -> f32 {
        self.inner.get_noise_2d(x, y)
    }

    pub fn get_1d(&self, x: f32) -> f32 {
        self.inner.get_noise_2d(x, 0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_and_range() {
        let mut p = Pcg::new(1);
        for _ in 0..1000 {
            let v = p.randi_range(-3, 7);
            assert!((-3..=7).contains(&v));
            let f = p.randf();
            assert!((0.0..=1.0).contains(&f));
        }
    }
}

/// Values Godot 4.5.2 printed for the same calls (tools/oracle_dump.gd).
#[cfg(test)]
mod godot_oracle {
    use super::*;

    #[test]
    fn rng() {
        let mut p = Pcg::new(12345);
        let ints: Vec<u32> = (0..4).map(|_| p.next_u32()).collect();
        assert_eq!(ints, [1321476956, 17539747, 3348728241, 2863338820]);
        let fs: Vec<f32> = (0..4).map(|_| p.randf_global()).collect();
        assert_eq!(fs, [0.01989850029349327, 0.23862190544605255, 0.9730542302131653, 0.24224168062210083]);
        assert_eq!(p.randf_range(20.0, 50.0), 46.19786608205173);
        assert_eq!(p.randi_range(60, 150), 65);
        assert_eq!(p.randi_range(-3, 7), -2);
    }

    #[test]
    fn hashes() {
        assert_eq!(hash(&Var::Array(&[Var::Int(123), Var::Int(4), Var::Int(-5)])), 342881257);
        assert_eq!(hash(&Var::Array(&[Var::Int(7), Var::Int(9), Var::Str("road surfaces")])), 3569785350);
        assert_eq!(hash(&Var::Array(&[Var::Int(4000000000), Var::Int(-1), Var::Int(2)])), 1771296908);
        assert_eq!(hash(&Var::Int(17)), 1785106064);
        assert_eq!(hash(&Var::Int(-2)), 340268856);
        let mut g = Pcg::new(342881257);
        assert_eq!(g.randf(), 0.7883471250534058);
        assert_eq!(g.randf_range_f32(-0.6, 0.6), 0.5615646839141846);
        assert_eq!(g.next_u32(), 952759554);
    }

    #[test]
    fn noise() {
        let n = Noise::new(987654321, 1.0 / 420.0, 3);
        let d = Noise::new(42, 1.0 / 70.0, 2);
        let w = Noise::with_defaults(11, 1.0 / 18.0);
        let want = [
            [0.07681920379400253, 0.3433709740638733, -0.38872671127319336, 0.16948074102401733],
            [0.22004882991313934, 0.25282618403434753, -0.2999945282936096, 0.0853596031665802],
            [-0.04168899357318878, 0.04833903908729553, 0.13958324491977692, 0.39375466108322144],
        ];
        for (i, (x, y)) in [(13.5f32, -800.25f32), (-1234.0, 567.0), (5000.5, 4999.5)].iter().enumerate() {
            let got = [n.get_2d(*x, *y), d.get_2d(*x, *y), w.get_1d(*x), d.get_1d(*y)];
            for k in 0..4 {
                assert_eq!(got[k] as f64, want[i][k], "point {i} value {k}");
            }
        }
    }
}
