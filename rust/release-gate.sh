#!/usr/bin/env bash
## FrameForge Rust release gate.
## 1. cargo test (all crates, all targets)
## 2. ff diff: 14/14 differentials in pure Rust
## 3. Godot headless: 14/14 differentials through the GDExtension
## Exits non-zero on any failure.

set -u
export PATH="$HOME/.cargo/bin:$PATH"
RUST_DIR="$(cd "$(dirname "$0")" && pwd)"
FF="$RUST_DIR/target/debug/ff"
GODOT="$HOME/workspace/tools/godot/Godot_v4.6-stable_linux.x86_64"
ORACLES="$HOME/workspace/frameforge/exit_gate/oracles"
BEHAVIORS="$RUST_DIR/behaviors"
PASS=0
FAIL=0

check() {
    if [ "$1" = "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $2"; fi
}

echo "=== 1. cargo test ==="
cargo test --offline --manifest-path "$RUST_DIR/Cargo.toml" 2>&1 | tail -3
check "${PIPESTATUS[0]}" "cargo test"

echo "=== 2. ff diff (pure Rust) ==="
run_diff() { # name behavior oracle tpf
    out=$("$FF" diff --behavior "$BEHAVIORS/$2" --oracle "$ORACLES/$3" \
        --name "$1" --ticks-per-frame "$4" 2>&1)
    echo "$out" | grep -q "PASS" && return 0 || { echo "$out"; return 1; }
}
D=0; F=0
for spec in \
  "walk_straight walk.json walk_straight.csv 1" \
  "walk_release walk.json walk_release.csv 1" \
  "walk_turn walk.json walk_turn.csv 1" \
  "jump_neutral_tap move.json jump_neutral.csv 1" \
  "jump_neutral_held move.json jump_neutral_held.csv 1" \
  "jump_forward jump_fwd.json jump_forward_held.csv 1" \
  "double_jump double_jump.json double_jump.csv 1" \
  "ground_pound ground_pound.json ground_pound.csv 1" \
  "long_jump_hand long_jump.json long_jump.csv 1" \
  "backflip backflip_chain.json backflip.csv 2" \
  "wall_kick wall_kick_chain.json wall_kick.csv 2" \
  "long_jump_baked long_jump_chain.json long_jump.csv 2" \
  "walk_chain walk_chain.json walk_forward_90f.csv 2" \
  "triple_jump triple_jump_baked.json triple_jump.csv 2"; do
    # shellcheck disable=SC2086
    if run_diff $spec; then D=$((D+1)); else F=$((F+1)); echo "FAIL: $spec"; fi
done
echo "ff diff: $D pass, $F fail"
[ "$F" = "0" ]; check "$?" "ff diff 14/14"

echo "=== 3. GDExtension gate (headless Godot) ==="
cd "$RUST_DIR/godot_test" || exit 1
# Rebuild the extension .so and copy it in.
cargo build --offline -p frameforge-godot 2>&1 | tail -1
cp "$RUST_DIR/target/debug/libframeforge_godot.so" bin/
out=$(timeout 300 "$GODOT" --headless --path . res://gate.tscn 2>&1)
echo "$out" | grep -E "GDExtension gate"
echo "$out" | grep -q "14 PASS, 0 FAIL"
check "$?" "GDExtension gate 14/14"

echo ""
echo "==== release gate: $PASS passed, $FAIL failed ===="
[ "$FAIL" = "0" ] && echo "ALL GREEN" || echo "FAILURES PRESENT"
exit "$FAIL"
