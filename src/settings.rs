//! Choices remembered between runs, in <config dir>/settings.json.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Serialize, Deserialize, Default, Clone)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub codec: Option<String>,        // hevc, h264, prores
    pub audio_format: Option<String>, // aac, pcm
    pub output_dir: Option<String>,
    pub monitor_output: Option<String>,
    pub scaling: Option<String>, // fill, fit, stretch (the browser's)
    /// Per plugin name: key → value the user chose in its settings.
    pub plugins: HashMap<String, HashMap<String, Value>>,
}

fn path() -> std::path::PathBuf {
    crate::config_dir().join("settings.json")
}

impl Settings {
    pub fn load() -> Settings {
        std::fs::read(path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let p = path();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let tmp = p.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(tmp, p);
            }
        }
    }
}
