#!/usr/bin/env python3
"""Exit-gate trajectory baker: stepkit trace -> baked trajectory JSON.

Two modes:
  bake.py --csv <trace.csv> --out <out.json>
  bake.py --scenario <scenario.json> --out <out.json> [--stepkit <binary>]

--scenario mode: JSON -> RON (ron_gen.py) -> `stepkit trace run` -> CSV,
then proceeds as --csv mode. Writes per-frame displacements in sim
units (cm) plus metadata.
"""
import argparse
import csv
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def csv_to_json(csv_path: str, out_path: str) -> None:
    frames = []
    with open(csv_path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            frames.append({
                "pos": [float(row["pos_x"]), float(row["pos_y"]), float(row["pos_z"])],
                "action": row["action"],
                "stick": [int(row["stick_x"]), int(row["stick_y"])],
                "buttons": int(row["buttons"]),
            })
    disps = []
    for i in range(len(frames) - 1):
        a, b = frames[i]["pos"], frames[i + 1]["pos"]
        disps.append([b[0] - a[0], b[1] - a[1], b[2] - a[2]])
    data = {
        "frames": len(frames),
        "start": frames[0]["pos"],
        "displacements": disps,
        "actions": [fr["action"] for fr in frames],
        "inputs": [{"stick": fr["stick"], "buttons": fr["buttons"]} for fr in frames],
    }
    with open(out_path, "w") as f:
        json.dump(data, f)
    print(f"baked {len(disps)} displacements ({len(frames)} frames) -> {out_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="")
    ap.add_argument("--scenario", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--stepkit", default=os.path.expanduser(
        "~/workspace/mario64_movement_plugin/target/debug/stepkit"))
    ap.add_argument("--workdir", default="/tmp/ff_bake")
    args = ap.parse_args()

    csv_path = args.csv
    if args.scenario:
        os.makedirs(args.workdir, exist_ok=True)
        with open(args.scenario) as f:
            sc_id = json.load(f)["id"]
        ron_path = os.path.join(args.workdir, sc_id + ".ron")
        csv_path = os.path.join(args.workdir, sc_id + ".csv")
        subprocess.run([sys.executable, os.path.join(HERE, "ron_gen.py"),
                        args.scenario, ron_path], check=True)
        subprocess.run([args.stepkit, "trace", "run",
                        "--scenario", ron_path, "--out", csv_path], check=True)
    csv_to_json(csv_path, args.out)


if __name__ == "__main__":
    main()
