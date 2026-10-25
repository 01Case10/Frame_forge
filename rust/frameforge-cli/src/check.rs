//! `ff check` — validate a behavior JSON file (port of FFValidator).
//! Prints issues as `severity: message [machine/state]`; exit 0 if no errors,
//! 1 if any errors, 2 on I/O failure.

use frameforge_core::validate::{validate_behavior, Severity};
use frameforge_core::FrameBehavior;

pub fn run(path: &str) -> Result<i32, String> {
    let bh = FrameBehavior::load_json(path).map_err(|e| format!("{}: {}", path, e))?;
    let issues = validate_behavior(&bh);
    let mut errors = 0;
    for iss in &issues {
        let sev = match iss.severity {
            Severity::Error => {
                errors += 1;
                "error"
            }
            Severity::Warning => "warning",
        };
        let loc = match (&iss.machine, &iss.state) {
            (Some(m), Some(s)) => format!(" [{}/{}]", m, s),
            (Some(m), None) => format!(" [{}]", m),
            _ => String::new(),
        };
        println!("{}: {}{}", sev, iss.message, loc);
    }
    if issues.is_empty() {
        println!("OK: no issues");
    }
    Ok(if errors > 0 { 1 } else { 0 })
}
