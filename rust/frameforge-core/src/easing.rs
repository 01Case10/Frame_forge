//! Godot-`Curve`-compatible easing sampling.
//!
//! Faithful port of Godot 4.6 `Curve::sample`, verified empirically against
//! the engine (see `exit_gate/sample_curve.gd` → `/tmp/curve_truth.json`).
//!
//! Established semantics:
//! - Empty curve → 0.0.
//! - Offset at/below first point x → first point y; at/above last x → last y.
//! - Between points: cubic Bezier with control values
//!   `yac = y0 + w*right_tangent/3`, `ybc = y1 - w*left_tangent/3`
//!   (tangents are dy/dx slopes, as stored by Godot).
//! - The sampled RESULT is NOT clamped to [min_value, max_value]
//!   (verified: 1.078125 returned with default max 1.0). Only `add_point`
//!   clamps stored y values — which already happened on the Godot side
//!   before export.
//!
//! Correction to the old `~/TOOLS.md` note ("sample() clamps"): wrong for
//! `sample()`; do not reintroduce clamping here.

use crate::model::EasingCurve;

/// Godot `Curve::sample(offset)`.
pub fn sample(curve: &EasingCurve, offset: f32) -> f32 {
    let pts = &curve.points;
    if pts.is_empty() {
        return 0.0;
    }
    if pts.len() == 1 || offset <= pts[0].pos[0] {
        return pts[0].pos[1];
    }
    let last = pts.len() - 1;
    if offset >= pts[last].pos[0] {
        return pts[last].pos[1];
    }
    let mut i = 0;
    while i + 1 < pts.len() && pts[i + 1].pos[0] <= offset {
        i += 1;
    }
    let x0 = pts[i].pos[0];
    let y0 = pts[i].pos[1];
    let x1 = pts[i + 1].pos[0];
    let y1 = pts[i + 1].pos[1];
    let w = x1 - x0;
    if w <= 0.0 {
        return y0;
    }
    let t = (offset - x0) / w;
    let yac = y0 + w * pts[i].right_tangent / 3.0;
    let ybc = y1 - w * pts[i + 1].left_tangent / 3.0;
    bezier(y0, yac, ybc, y1, t)
}

fn bezier(p0: f32, c1: f32, c2: f32, p3: f32, t: f32) -> f32 {
    let omt = 1.0 - t;
    let omt2 = omt * omt;
    let omt3 = omt2 * omt;
    let t2 = t * t;
    let t3 = t2 * t;
    p0 * omt3 + 3.0 * c1 * omt2 * t + 3.0 * c2 * omt * t2 + p3 * t3
}

/// Per-frame shape weight, mirroring `behavior_player.gd` `_precompute`:
/// `st.easing.sample(float(k) / float(n))`.
pub fn weight(curve: &EasingCurve, frame: u32, duration_frames: u32) -> f32 {
    let n = duration_frames.max(1) as f32;
    sample(curve, frame as f32 / n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::CurvePoint;

    fn curve(pts: Vec<([f32; 2], f32, f32)>, min: f32, max: f32) -> EasingCurve {
        EasingCurve {
            points: pts
                .into_iter()
                .map(|(pos, lt, rt)| CurvePoint {
                    pos,
                    left_tangent: lt,
                    right_tangent: rt,
                })
                .collect(),
            min_value: min,
            max_value: max,
        }
    }

    fn assert_samples(c: &EasingCurve, cases: &[(f32, f32)]) {
        for (offset, expected) in cases {
            let got = sample(c, *offset);
            assert!(
                (got - expected).abs() < 1e-5,
                "offset {}: got {}, expected {}",
                offset,
                got,
                expected
            );
        }
    }

    /// Ground truth from Godot 4.6 (`exit_gate/sample_curve.gd`).
    #[test]
    fn matches_godot_sample() {
        // Flat default easing.
        let flat = curve(
            vec![([0.0, 1.0], 0.0, 0.0), ([1.0, 1.0], 0.0, 0.0)],
            0.0,
            1.0,
        );
        assert_samples(
            &flat,
            &[
                (0.0, 1.0),
                (0.25, 1.0),
                (0.5, 1.0),
                (0.75, 1.0),
                (1.0, 1.0),
                (-0.1, 1.0),
                (1.1, 1.0),
            ],
        );

        // Smooth 3-pt cubic (zero tangents).
        let smooth = curve(
            vec![
                ([0.0, 0.0], 0.0, 0.0),
                ([0.5, 1.0], 0.0, 0.0),
                ([1.0, 0.0], 0.0, 0.0),
            ],
            0.0,
            1.0,
        );
        assert_samples(
            &smooth,
            &[
                (0.0, 0.0),
                (0.125, 0.15625),
                (0.25, 0.5),
                (0.375, 0.84375),
                (0.5, 1.0),
                (0.625, 0.84375),
                (0.75, 0.5),
                (0.875, 0.15625),
                (1.0, 0.0),
            ],
        );

        // Explicit tangents; overshoot NOT clamped (1.078125 > max 1.0).
        let tan = curve(
            vec![([0.0, 0.0], 0.0, 2.0), ([1.0, 1.0], -1.0, 0.0)],
            0.0,
            1.0,
        );
        assert_samples(
            &tan,
            &[
                (0.0, 0.0),
                (0.25, 0.484375),
                (0.5, 0.875),
                (0.75, 1.078125),
                (1.0, 1.0),
            ],
        );

        // Linear ramp (TANGENT_LINEAR auto-slopes).
        let lin = curve(
            vec![
                ([0.0, 0.0], 0.0, 1.0),
                ([0.5, 0.5], 1.0, 1.0),
                ([1.0, 1.0], 1.0, 0.0),
            ],
            0.0,
            1.0,
        );
        assert_samples(
            &lin,
            &[
                (0.0, 0.0),
                (0.125, 0.125),
                (0.25, 0.25),
                (0.5, 0.5),
                (0.75, 0.75),
                (1.0, 1.0),
            ],
        );

        // Out-of-range offsets return endpoint values.
        let oor = curve(
            vec![([0.2, 0.3], 0.0, 0.0), ([0.8, 0.9], 0.0, 0.0)],
            0.0,
            1.0,
        );
        assert_samples(
            &oor,
            &[
                (-1.0, 0.3),
                (0.0, 0.3),
                (0.2, 0.3),
                (0.5, 0.6),
                (0.8, 0.9),
                (1.0, 0.9),
                (2.0, 0.9),
            ],
        );

        // Empty and single-point.
        let empty = curve(vec![], 0.0, 1.0);
        assert_samples(&empty, &[(0.0, 0.0), (0.5, 0.0), (1.0, 0.0)]);
        let single = curve(vec![([0.4, 0.7], 0.0, 0.0)], 0.0, 1.0);
        assert_samples(&single, &[(0.0, 0.7), (0.4, 0.7), (0.7, 0.7), (1.0, 0.7)]);
    }

    #[test]
    fn weight_matches_runtime_sampling() {
        // Fitted-style curve: points exactly at k/n land on the points.
        let c = curve(
            vec![
                ([0.0, 0.2], 0.0, 0.0),
                ([0.25, 0.4], 0.0, 0.0),
                ([0.5, 0.6], 0.0, 0.0),
                ([0.75, 0.8], 0.0, 0.0),
            ],
            0.0,
            1.0,
        );
        assert!((weight(&c, 0, 4) - 0.2).abs() < 1e-6);
        assert!((weight(&c, 1, 4) - 0.4).abs() < 1e-6);
        assert!((weight(&c, 3, 4) - 0.8).abs() < 1e-6);
    }
}
