//! Car numbers, read from data/cars.toml at run time so tuning needs no
//! rebuild. A model's table is merged over the base table.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CarSpec {
    pub name: String,
    #[serde(default)]
    pub model: String,
    pub mass: f64,
    pub inertia: [f64; 3],
    pub cg: [f64; 3],
    pub wheelbase: f64,
    pub track: f64,
    #[serde(default)]
    pub track_rear: Option<f64>,
    pub wheel_radius: f64,
    pub wheel_inertia: f64,
    pub droop_y: f64,
    pub travel: f64,
    pub spring: [f64; 2],
    pub bump: [f64; 2],
    pub rebound: [f64; 2],
    pub arb: [f64; 2],
    pub max_steer_deg: f64,
    pub brake: [f64; 2],
    pub handbrake: f64,
    pub drive: [f64; 2],
    pub centre_lock: f64,
    pub diff_preload: [f64; 2],
    pub diff_ramp: [f64; 2],
    pub idle_rpm: f64,
    pub limit_rpm: f64,
    pub engine_inertia: f64,
    pub torque: Vec<[f64; 2]>,
    pub friction: [f64; 2],
    pub gears: Vec<f64>,
    #[serde(rename = "final")]
    pub final_drive: f64,
    pub shift_time: f64,
    pub clutch: f64,
    pub upshift_rpm: f64,
    pub downshift_rpm: f64,
    pub drag: f64,
    pub downforce: f64,
    #[serde(default)]
    pub ride: f64,
    /// [size x, y, z, centre x, y, z]
    pub boxes: Vec<[f64; 6]>,
}

impl CarSpec {
    pub fn max_steer(&self) -> f64 {
        self.max_steer_deg * (std::f64::consts::PI / 180.0)
    }
    pub fn track_rear(&self) -> f64 {
        self.track_rear.unwrap_or(self.track)
    }
}

pub const GRID: [&str; 3] = ["asti", "mv6", "toyama"];

/// All cars: "base" plus every model merged over it.
pub struct Cars {
    table: toml::Table,
}

pub const DEFAULT_CARS: &str = include_str!("../../../data/cars.toml");

impl Cars {
    /// The data file next to the engine, or the copy built in.
    pub fn load(path: Option<&str>) -> Result<Cars, String> {
        let text = match path {
            Some(p) => std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?,
            None => {
                let local = concat!(env!("CARGO_MANIFEST_DIR"), "/../../data/cars.toml");
                std::fs::read_to_string(local).unwrap_or_else(|_| DEFAULT_CARS.to_string())
            }
        };
        let table: toml::Table = text.parse().map_err(|e| format!("cars.toml: {e}"))?;
        Ok(Cars { table })
    }

    pub fn get(&self, id: &str) -> Result<CarSpec, String> {
        let mut merged = self.table.get("base").and_then(|b| b.as_table()).cloned().ok_or("cars.toml has no [base]")?;
        if id != "rally2" && id != "base" {
            let model = self
                .table
                .get("models")
                .and_then(|m| m.get(id))
                .and_then(|m| m.as_table())
                .ok_or_else(|| format!("no car '{id}'"))?;
            for (k, v) in model {
                merged.insert(k.clone(), v.clone());
            }
        }
        toml::Value::Table(merged).try_into().map_err(|e| format!("car '{id}': {e}"))
    }
}
