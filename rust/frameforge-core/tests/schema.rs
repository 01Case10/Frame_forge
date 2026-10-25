//! Phase 0 gate: every exported behavior JSON must deserialize into the
//! Rust model and serialize back losslessly.
//!
//! Fixtures live in `rust/behaviors/*.json`, produced by
//! `exit_gate/export_json.gd` from the `.tres` behaviors.

use frameforge_core::FrameBehavior;
use std::fs;

fn behavior_files() -> Vec<String> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../behaviors");
    let mut files: Vec<String> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read {}: {} (run exit_gate/export_json.gd first)", dir, e))
        .filter_map(|e| e.ok())
        .map(|e| e.path().to_string_lossy().into_owned())
        .filter(|p| p.ends_with(".json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no behavior JSON fixtures in {}", dir);
    files
}

#[test]
fn all_behaviors_deserialize() {
    for f in behavior_files() {
        let b = FrameBehavior::load_json(&f).unwrap_or_else(|e| panic!("{}: {}", f, e));
        assert!(!b.behavior_name.is_empty(), "{}: empty behavior_name", f);
        assert!(!b.sub_machines.is_empty(), "{}: no sub-machines", f);
        for m in &b.sub_machines {
            assert!(
                !m.states.is_empty(),
                "{}: machine {} has no states",
                f,
                m.machine_name
            );
            assert!(
                m.states.iter().any(|s| s.state_name == m.entry_state_name),
                "{}: machine {} entry '{}' not found",
                f,
                m.machine_name,
                m.entry_state_name
            );
            // Every transition target must resolve within its machine.
            for s in &m.states {
                for t in &s.transitions {
                    assert!(
                        m.states.iter().any(|d| d.state_name == t.target_state_name),
                        "{}: {}.{} -> unknown state '{}'",
                        f,
                        m.machine_name,
                        s.state_name,
                        t.target_state_name
                    );
                }
            }
        }
    }
}

#[test]
fn json_round_trip_is_lossless() {
    for f in behavior_files() {
        let text = fs::read_to_string(&f).unwrap();
        let b: FrameBehavior = serde_json::from_str(&text).unwrap();
        let back = serde_json::to_string_pretty(&b).unwrap();
        let b2: FrameBehavior = serde_json::from_str(&back).unwrap();
        assert_eq!(b, b2, "{}: round-trip mismatch", f);
    }
}
