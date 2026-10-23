//! Grip per surface (src/surfaces.gd). A normalised Pacejka curve: 1.0 is
//! the slip at the peak, and C sets how much grip remains when sliding.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Hash)]
#[repr(u8)]
pub enum Surface {
    Gravel = 0,
    Loose = 1,
    Grass = 2,
    Dirt = 3,
    Water = 4,
    Asphalt = 5,
    Mud = 6,
}

impl Surface {
    pub const ALL: [Surface; 7] = [Surface::Gravel, Surface::Loose, Surface::Grass, Surface::Dirt, Surface::Water, Surface::Asphalt, Surface::Mud];

    pub fn from_u8(v: u8) -> Surface {
        *Surface::ALL.get(v as usize).unwrap_or(&Surface::Gravel)
    }

    pub fn name(self) -> &'static str {
        ["gravel", "loose", "grass", "dirt", "water", "asphalt", "mud"][self as usize]
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Grip {
    pub mu: f64,
    pub kappa_peak: f64,
    pub alpha_peak: f64,
    #[serde(rename = "C")]
    pub c: f64,
    pub rolling: f64,
    pub drag: f64,
}

/// The authored table, then weather applied on a copy.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Surfaces {
    pub table: [Grip; 7],
}

const fn g(mu: f64, kappa_peak: f64, alpha_peak: f64, c: f64, rolling: f64, drag: f64) -> Grip {
    Grip { mu, kappa_peak, alpha_peak, c, rolling, drag }
}

pub const TABLE: [Grip; 7] = [
    g(1.0, 0.16, 0.19, 1.3, 0.022, 0.0),
    g(0.86, 0.20, 0.22, 1.25, 0.035, 0.0),
    g(0.7, 0.14, 0.18, 1.4, 0.06, 120.0),
    g(0.8, 0.18, 0.21, 1.3, 0.08, 200.0),
    g(0.62, 0.14, 0.18, 1.4, 0.05, 0.0),
    g(1.12, 0.11, 0.13, 1.5, 0.012, 0.0),
    g(0.70, 0.22, 0.25, 1.25, 0.08, 200.0),
];

impl Default for Surfaces {
    fn default() -> Self {
        Surfaces { table: TABLE }
    }
}

impl Surfaces {
    pub fn get(&self, s: Surface) -> &Grip {
        &self.table[s as usize]
    }

    /// Wet asphalt and mud lose grip; the authored table stays untouched.
    pub fn with_wetness(base: &Surfaces, wet: f64) -> Surfaces {
        let a = wet.clamp(0.0, 1.0);
        let mut s = base.clone();
        let l = |x: f64, y: f64| x + (y - x) * a;
        let asph = Surface::Asphalt as usize;
        let mud = Surface::Mud as usize;
        s.table[asph].mu = l(base.table[asph].mu, 0.86);
        s.table[asph].rolling = l(base.table[asph].rolling, 0.014);
        s.table[mud].mu = l(base.table[mud].mu, 0.56);
        s.table[mud].rolling = l(base.table[mud].rolling, 0.10);
        s.table[mud].drag = l(base.table[mud].drag, 260.0);
        s
    }
}

/// Normalised magic formula: 0 at s = 0, 1 at the peak (s = 1).
pub fn curve(s: f64, c: f64) -> f64 {
    let b = (std::f64::consts::PI / (2.0 * c)).tan();
    (c * (b * s).atan()).sin()
}
