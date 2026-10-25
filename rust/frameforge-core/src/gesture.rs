//! Stick-gesture detection (G-4): the spin validator.
//!
//! Transcribes the guard vocabulary's `spin_valid`: a stick rotation of
//! `min_frames..=max_frames` consecutive ticks whose swept sector area is at
//! least `min_area` square units and whose first and last stick angles are
//! within `angle_tolerance_deg` of each other. A completed detection stays
//! valid for `buffer_ticks` afterwards (the "30-frame window to start").
//!
//! Any non-zero stick radius counts as non-neutral for the detector (unlike
//! the 0.1 neutral zone used by movement guards).

use crate::model::SpinDetectConfig;
use std::f32::consts::PI;

/// Smallest radius that counts as "stick moved" for gesture purposes.
const GESTURE_EPS: f32 = 1e-3;

fn ang_diff(a: f32, b: f32) -> f32 {
    // Signed difference a - b wrapped to (-PI, PI].
    let mut d = (a - b) % (2.0 * PI);
    if d <= -PI {
        d += 2.0 * PI;
    } else if d > PI {
        d -= 2.0 * PI;
    }
    d
}

#[derive(Debug, Clone, Default)]
pub struct SpinDetector {
    cfg: Option<SpinDetectConfig>,
    /// (angle_rad, radius) for the current consecutive run.
    run: Vec<(f32, f32)>,
    /// Ticks since the current run started (== run.len(), kept explicit).
    tick: u64,
    /// The detector output stays true through this tick (inclusive).
    valid_until: u64,
    /// Set when a fresh detection completed this tick (for tests/inspection).
    pub completed_this_tick: bool,
}

impl SpinDetector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn configure(&mut self, cfg: Option<SpinDetectConfig>) {
        self.cfg = cfg;
        self.run.clear();
        self.valid_until = 0;
    }

    pub fn output_param(&self) -> Option<&str> {
        self.cfg.as_ref().map(|c| c.output_param.as_str())
    }

    pub fn is_active(&self) -> bool {
        self.cfg.is_some()
    }

    /// Feed one tick of stick input. Call once per tick, before row
    /// evaluation, so the output is visible to conditions the same tick.
    pub fn push_stick(&mut self, x: f32, y: f32) {
        self.tick = self.tick.wrapping_add(1);
        self.completed_this_tick = false;
        let cfg = match &self.cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let r = (x * x + y * y).sqrt();
        if r < GESTURE_EPS {
            // Neutral stick breaks the consecutive run.
            self.run.clear();
            return;
        }
        let ang = y.atan2(x);
        // Direction consistency: every step must continue the initial turn.
        if let Some(&(prev_ang, _)) = self.run.last() {
            let step = ang_diff(ang, prev_ang);
            if step.abs() < 1e-6 {
                return; // no rotation this tick; run neither grows nor breaks
            }
            let first_step = {
                let (a0, _) = self.run[0];
                let (a1, _) = self.run[1.min(self.run.len() - 1)];
                if self.run.len() >= 2 {
                    ang_diff(a1, a0)
                } else {
                    step
                }
            };
            if self.run.len() >= 2 && step.signum() != first_step.signum() {
                // Reversed direction: start a new run from the previous sample.
                self.run.clear();
                self.run.push((prev_ang, r));
            }
        }
        self.run.push((ang, r));
        // Cap the stored run; a run longer than max_frames can never validate
        // until the stick goes neutral and a new run starts.
        let max_keep = cfg.max_frames.max(2) as usize;
        if self.run.len() > max_keep {
            self.run.drain(0..self.run.len() - max_keep);
        }
        if self.check_valid(&cfg) {
            self.valid_until = self.tick + cfg.buffer_ticks as u64;
            self.completed_this_tick = true;
        }
    }

    fn check_valid(&self, cfg: &SpinDetectConfig) -> bool {
        let n = self.run.len() as u32;
        if n < cfg.min_frames || n > cfg.max_frames || n < 2 {
            return false;
        }
        // First/last angles within tolerance.
        let (a_first, _) = self.run[0];
        let (a_last, _) = self.run[self.run.len() - 1];
        let span = ang_diff(a_last, a_first).abs() * 180.0 / PI;
        if span > cfg.angle_tolerance_deg {
            return false;
        }
        // Swept sector area: sum 0.5 * r_avg^2 * |dtheta|.
        let mut area = 0.0f32;
        for w in self.run.windows(2) {
            let (a0, r0) = w[0];
            let (a1, r1) = w[1];
            let d = ang_diff(a1, a0).abs();
            let ra = 0.5 * (r0 + r1);
            area += 0.5 * ra * ra * d;
        }
        area >= cfg.min_area
    }

    /// True while a recent detection's buffer window is open.
    pub fn valid(&self) -> bool {
        self.cfg.is_some() && self.tick <= self.valid_until && self.valid_until > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> SpinDetectConfig {
        SpinDetectConfig::default()
    }

    /// Feed a steady rotation: `frames` ticks, radius 1, `deg_per` per tick.
    fn rotate(det: &mut SpinDetector, frames: u32, deg_per: f32) {
        for i in 0..frames {
            let a = (i as f32) * deg_per * PI / 180.0;
            det.push_stick(a.cos(), a.sin());
        }
    }

    #[test]
    fn detects_full_rotation() {
        let mut d = SpinDetector::new();
        d.configure(Some(cfg()));
        // 70 frames x 10 deg = 700 deg ~= two full turns (the documented
        // gesture): first/last within tolerance, swept area >= 5.
        rotate(&mut d, 70, 10.0);
        assert!(d.valid(), "two full turns should validate");
        assert!(d.completed_this_tick);
    }

    #[test]
    fn rejects_too_short() {
        let mut d = SpinDetector::new();
        d.configure(Some(cfg()));
        rotate(&mut d, 20, 10.0);
        assert!(!d.valid(), "20 frames is below the 31-frame minimum");
    }

    #[test]
    fn rejects_direction_reversal() {
        let mut d = SpinDetector::new();
        d.configure(Some(cfg()));
        rotate(&mut d, 20, 10.0);
        // Reverse: the run restarts, so it never reaches 31 frames.
        for i in 0..20 {
            let a = (200.0 - i as f32 * 10.0) * PI / 180.0;
            d.push_stick(a.cos(), a.sin());
        }
        assert!(!d.valid());
    }

    #[test]
    fn neutral_breaks_run() {
        let mut d = SpinDetector::new();
        d.configure(Some(cfg()));
        rotate(&mut d, 20, 10.0);
        d.push_stick(0.0, 0.0);
        rotate(&mut d, 20, 10.0);
        assert!(!d.valid(), "neutral stick must break the run");
    }

    #[test]
    fn buffer_window() {
        let mut d = SpinDetector::new();
        d.configure(Some(cfg()));
        rotate(&mut d, 70, 10.0);
        assert!(d.valid());
        // Stop rotating (neutral); the 30-tick buffer keeps it valid...
        for _ in 0..30 {
            d.push_stick(0.0, 0.0);
        }
        assert!(d.valid(), "still within the 30-tick buffer");
        d.push_stick(0.0, 0.0);
        assert!(!d.valid(), "buffer expired after 31 ticks");
    }

    #[test]
    fn inactive_without_config() {
        let mut d = SpinDetector::new();
        rotate(&mut d, 36, 10.0);
        assert!(!d.valid());
    }
}
