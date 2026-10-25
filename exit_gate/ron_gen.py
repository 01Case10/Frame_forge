#!/usr/bin/env python3
"""Exit-gate scenario authoring: JSON -> stepkit scenario RON.

JSON schema:
{
  "id": "walk_forward",
  "tags": ["ground", "walk"],
  "geometry": [{"min": [-2000,-100,-2000], "max": [2000,0,2000], "kind": 0}],
  "start": {"pos": [0,0,0], "yaw_deg": 0.0, "action": "Idle"},
  "camera_yaw_deg": 0.0,
  "compare": "GroundDefault",          # or "AirDefault"
  "inputs": [{"frames": 60, "stick": [0,80], "buttons": 0}]
}
Buttons bitmask: A=0x1, B=0x2, Z=0x4 (stepkit-core input::buttons).
Stick is i8 (-128..127); 80 ~= full tilt.

Usage: ron_gen.py <scenario.json> <out.ron>
"""
import json
import sys


def fmt_num(v) -> str:
    if isinstance(v, float) and v.is_integer():
        return f"{v:.1f}"
    return str(v)


def main() -> None:
    json_path, ron_path = sys.argv[1], sys.argv[2]
    with open(json_path) as f:
        sc = json.load(f)

    def box(g) -> str:
        mn = ", ".join(fmt_num(v) for v in g["min"])
        mx = ", ".join(fmt_num(v) for v in g["max"])
        return (f"        Box((\n            min: ({mn}),\n"
                f"            max: ({mx}),\n            kind: {g.get('kind', 0)},\n        )),\n")

    def inp(seg) -> str:
        sx, sy = seg["stick"]
        assert -128 <= sx <= 127 and -128 <= sy <= 127, f"stick out of i8 range: {seg['stick']}"
        return (f"        Hold(\n            frames: {seg['frames']},\n"
                f"            stick: ({sx}, {sy}),\n            buttons: {seg['buttons']},\n        ),\n")

    st = sc["start"]
    pos = ", ".join(fmt_num(v) for v in st["pos"])
    tags = ",\n".join(f'        "{t}"' for t in sc.get("tags", []))
    ron = (
        "(\n"
        f'    id: "{sc["id"]}",\n'
        "    tags: [\n" + (tags + ",\n" if tags else "") + "    ],\n"
        "    geometry: [\n" + "".join(box(g) for g in sc["geometry"]) + "    ],\n"
        "    start: (\n"
        f"        pos: ({pos}),\n"
        f"        yaw_deg: {fmt_num(st.get('yaw_deg', 0.0))},\n"
        f'        action: "{st.get("action", "Idle")}",\n'
        "    ),\n"
        "    camera: Fixed(\n"
        f"        yaw_deg: {fmt_num(sc.get('camera_yaw_deg', 0.0))},\n"
        "    ),\n"
        "    inputs: [\n" + "".join(inp(s) for s in sc["inputs"]) + "    ],\n"
        f"    compare: {sc.get('compare', 'GroundDefault')},\n"
        ")\n"
    )
    with open(ron_path, "w") as f:
        f.write(ron)
    print(f"wrote {ron_path}")


if __name__ == "__main__":
    main()
