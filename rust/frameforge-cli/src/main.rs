//! `ff` — FrameForge headless toolchain.
//!
//! Subcommands mirror the exit-gate scripts:
//! - `ff diff`  ← run_gate.gd/tscn (differential vs stepkit oracle)
//! - `ff check` ← FFValidator
//! - `ff dump`  ← per-tick trace debugging
//! - `ff bake`  ← bake.py + ron_gen.py + build_baked.gd (absorbed, post-gate)

mod bake;
mod check;
mod diff;
mod dump;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "ff", about = "FrameForge headless toolchain")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Differential: replay a behavior vs a stepkit oracle CSV.
    /// Tolerances (stepkit cm): mean < 0.5, max < 2.0, final < 1.0.
    Diff {
        #[arg(long)]
        behavior: String,
        #[arg(long)]
        oracle: String,
        #[arg(long, default_value_t = 2)]
        ticks_per_frame: u32,
        #[arg(long, default_value = "gate")]
        name: String,
    },
    /// Validate a behavior JSON file.
    Check { file: String },
    /// Dump the per-tick position trace for debugging.
    Dump {
        #[arg(long)]
        behavior: String,
        #[arg(long)]
        scenario: String,
        #[arg(long, default_value_t = 1)]
        ticks_per_frame: u32,
    },
    /// Bake a stepkit scenario JSON into a behavior JSON chain.
    Bake {
        scenario: String,
        #[arg(long)]
        out: String,
        #[arg(long, default_value = "Baked")]
        name: String,
        #[arg(long, default_value = concat!(env!("HOME"), "/workspace/mario64_movement_plugin/target/debug/stepkit"))]
        stepkit: String,
    },
}

fn main() {
    let cli = Cli::parse();
    let code = match cli.cmd {
        Cmd::Diff {
            behavior,
            oracle,
            ticks_per_frame,
            name,
        } => cmd_diff(&behavior, &oracle, ticks_per_frame, &name),
        Cmd::Check { file } => match check::run(&file) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("ff check: {}", e);
                2
            }
        },
        Cmd::Dump {
            behavior,
            scenario,
            ticks_per_frame,
        } => match dump::run(&behavior, &scenario, ticks_per_frame) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("ff dump: {}", e);
                2
            }
        },
        Cmd::Bake {
            scenario,
            out,
            name,
            stepkit,
        } => match bake::run(&scenario, &out, &name, &stepkit) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("ff bake: {}", e);
                2
            }
        },
    };
    std::process::exit(code);
}

fn cmd_diff(behavior: &str, oracle_path: &str, ticks_per_frame: u32, name: &str) -> i32 {
    let oracle = match diff::load_oracle(oracle_path) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("ff diff: oracle: {}", e);
            return 2;
        }
    };
    match diff::run(behavior, &oracle, ticks_per_frame) {
        Ok(r) => {
            println!(
                "==== {}: frames={} mean={:.4}cm max={:.4}cm final={:.4}cm -> {} ====",
                name,
                r.frames,
                r.mean,
                r.max,
                r.final_err,
                if r.passed { "PASS" } else { "FAIL" }
            );
            if r.passed {
                0
            } else {
                1
            }
        }
        Err(e) => {
            eprintln!("ff diff: {}", e);
            2
        }
    }
}
