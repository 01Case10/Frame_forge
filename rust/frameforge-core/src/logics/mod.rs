//! G-6 built-in state logics.

pub mod ledgegrab;
pub mod poleclimb;
pub mod smg_crawl;
pub mod smg_hang;
pub mod smg_physics;
pub mod wallrun;

use crate::logic::LogicFactory;
use std::collections::HashMap;

/// (name, factory) for every built-in logic. `Runtime::new` registers these.
/// Must match `logic::BUILTIN_LOGIC_NAMES` (checked by unit test below).
pub fn builtin_factories() -> Vec<(&'static str, LogicFactory)> {
    vec![
        ("wallrun", wallrun::Wallrun::factory()),
        ("ledgegrab", ledgegrab::LedgeGrab::factory()),
        ("poleclimb", poleclimb::PoleClimb::factory()),
        ("smg_crawl", smg_crawl::SmgCrawl::factory()),
        ("smg_hang", smg_hang::SmgHang::factory()),
        ("smg_physics", smg_physics::SmgPhysics::factory()),
    ]
}

/// Convenience: name -> factory map for `Runtime::new`.
pub fn builtin_registry() -> HashMap<String, LogicFactory> {
    builtin_factories()
        .into_iter()
        .map(|(n, f)| (n.to_string(), f))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::logic::BUILTIN_LOGIC_NAMES;

    #[test]
    fn builtin_names_match_const() {
        let mut a: Vec<&str> = builtin_factories().iter().map(|(n, _)| *n).collect();
        a.sort_unstable();
        let mut b: Vec<&str> = BUILTIN_LOGIC_NAMES.to_vec();
        b.sort_unstable();
        assert_eq!(a, b);
    }
}
