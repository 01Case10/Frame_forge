#!/usr/bin/env python3
"""Render the SMO showcase state-trace video from trace_capture.csv.

Temporary research file. Output: ~/workspace/your_files/frameforge_smo_showcase_trace.mp4
Top panel: side-view trajectory (forward distance vs height), follow-cam, trail
colored by Nerves state family. Bottom panel: Nerves + Cap state timeline strips
with playhead. 30 fps, 2 ticks per frame.
"""
import csv, math, os, subprocess, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

CSV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trace_capture.csv")
OUT = os.path.expanduser("~/workspace/your_files/frameforge_smo_showcase_trace.mp4")
TMPDIR = "/tmp/smo_trace_frames"

# state -> (family, color)
FAM = {
    "idle": ("ground", "#9aa0a6"), "run": ("ground", "#34a853"),
    "brake_stop": ("ground", "#fb8c00"), "brake_turn": ("ground", "#fb8c00"),
    "pivot": ("ground", "#fb8c00"), "pivot_moving": ("ground", "#fb8c00"),
    "crouch_idle": ("ground", "#8d6e63"), "crouch_walk": ("ground", "#8d6e63"),
    "crouch_slide": ("ground", "#8d6e63"), "uncrouch": ("ground", "#8d6e63"),
    "roll": ("ground", "#6d4c41"),
    "coyote": ("air", "#fdd835"),
    "jump_select": ("air", "#90caf9"), "jump1": ("air", "#42a5f5"),
    "jump1_cut": ("air", "#1e88e5"), "jump2": ("air", "#42a5f5"),
    "jump2_cut": ("air", "#1e88e5"), "jump3": ("air", "#42a5f5"),
    "jump_long": ("air", "#3949ab"), "jump_wall": ("air", "#5c6bc0"),
    "jump_back": ("air", "#5c6bc0"), "jump_side": ("air", "#5c6bc0"),
    "fall": ("air", "#ef5350"), "land_sel": ("air", "#ab47bc"),
    "gp_stall": ("pound", "#ec407a"), "gp_fall": ("pound", "#d81b60"),
    "dive": ("pound", "#e53935"),
    "cap_throw": ("cap", "#26a69a"), "cap_throw_air": ("cap", "#26a69a"),
    "wall_slide": ("wall", "#78909c"), "wall_push": ("wall", "#78909c"),
    "knockback": ("hurt", "#b71c1c"), "knockback_land": ("hurt", "#b71c1c"),
}
CAP_COLORS = {"cap_held": "#9aa0a6", "cap_flying": "#42a5f5",
              "cap_hover": "#26c6da", "cap_homing": "#ab47bc",
              "cap_returning": "#fb8c00"}

def fam_color(state):
    return FAM.get(state, ("other", "#bdbdbd"))[1]

def main():
    rows = []
    with open(CSV) as f:
        for r in csv.reader(f, delimiter="|"):
            rows.append(r)
    n = len(rows)
    ticks = np.array([int(r[0]) for r in rows])
    segs = [r[1] for r in rows]
    nerves = [r[2] for r in rows]
    caps = [r[3] for r in rows]
    z = np.array([float(r[6]) for r in rows])      # forward distance
    y = np.array([float(r[5]) for r in rows])      # height

    print(f"ticks={n} zmax={z.max():.0f} ymax={y.max():.0f}")
    print("nerves states seen:", sorted(set(nerves)))
    print("cap states seen:", sorted(set(caps)))

    # --- precompute timeline strip image (2 rows x n ticks) ---
    strip = np.ones((2, n, 3))
    import matplotlib.colors as mcolors
    for i, s in enumerate(nerves):
        strip[0, i] = mcolors.to_rgb(fam_color(s))
    for i, s in enumerate(caps):
        strip[1, i] = mcolors.to_rgb(CAP_COLORS.get(s, "#bdbdbd"))

    os.makedirs(TMPDIR, exist_ok=True)
    for f in os.listdir(TMPDIR):
        os.remove(os.path.join(TMPDIR, f))

    FPS, TPF = 30, 2  # ticks per frame
    nframes = math.ceil(n / TPF)
    fig = plt.figure(figsize=(11.52, 6.48), dpi=100)
    gs = fig.add_gridspec(2, 1, height_ratios=[3, 1], hspace=0.25)
    ax1 = fig.add_subplot(gs[0])
    ax2 = fig.add_subplot(gs[1])

    # bottom strip (static)
    ax2.imshow(strip, aspect="auto", extent=[0.5, n + 0.5, -0.5, 1.5],
               interpolation="nearest", origin="upper")
    ax2.set_yticks([0, 1]); ax2.set_yticklabels(["Nerves", "Cap"], fontsize=9)
    ax2.set_xlim(0.5, n + 0.5); ax2.set_xlabel("tick (60 Hz)")
    playhead, = ax2.plot([1, 1], [-0.5, 1.5], color="black", lw=1.5)

    # top panel static bits
    ax1.axhline(0, color="#5d4037", lw=2)
    ax1.set_xlabel("forward distance (units)")
    ax1.set_ylabel("height (units)")
    ax1.grid(True, alpha=0.25)
    legend_items = [Patch(color=c, label=fam) for fam, c in
                    [("ground", "#34a853"), ("air", "#42a5f5"),
                     ("pound/dive", "#e53935"), ("cap action", "#26a69a")]]
    ax1.legend(handles=legend_items, loc="upper left", fontsize=8, ncol=4)
    title = ax1.set_title("", fontsize=14, loc="left")

    TRAIL = 150
    for fr in range(nframes):
        i = min(fr * TPF, n - 1)
        # follow cam
        zc = z[i]
        ax1.set_xlim(zc - 500, zc + 1500)
        ax1.set_ylim(-80, 700)
        # trail
        j0 = max(0, i - TRAIL)
        xs, ys, cs = z[j0:i + 1], y[j0:i + 1], [fam_color(s) for s in nerves[j0:i + 1]]
        ax1.clear()
        ax1.axhline(0, color="#5d4037", lw=2)
        ax1.grid(True, alpha=0.25)
        ax1.set_xlabel("forward distance (units)")
        ax1.set_ylabel("height (units)")
        ax1.legend(handles=legend_items, loc="upper left", fontsize=8, ncol=4)
        ax1.set_xlim(zc - 500, zc + 1500)
        ax1.set_ylim(-80, 700)
        ax1.scatter(xs, ys, c=cs, s=14, alpha=0.85, zorder=3)
        ax1.scatter([z[i]], [y[i]], c=[fam_color(nerves[i])], s=160,
                    edgecolors="black", linewidths=1.2, zorder=4)
        ax1.text(0.99, 0.02, f"state: {nerves[i]}   cap: {caps[i]}",
                 transform=ax1.transAxes, ha="right", va="bottom", fontsize=10,
                 bbox=dict(boxstyle="round,pad=0.3", fc="white", alpha=0.8))
        title = ax1.set_title(f"{segs[i]}   (t={ticks[i]}, {ticks[i]/60:.1f}s)",
                              fontsize=14, loc="left")
        playhead.set_xdata([ticks[i], ticks[i]])
        fig.savefig(os.path.join(TMPDIR, f"f{fr:05d}.png"))
        if fr % 200 == 0:
            print(f"frame {fr}/{nframes}", flush=True)

    plt.close(fig)
    subprocess.run(["ffmpeg", "-y", "-framerate", str(FPS), "-i",
                    os.path.join(TMPDIR, "f%05d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20",
                    OUT], check=True)
    print("wrote", OUT, os.path.getsize(OUT), "bytes")

if __name__ == "__main__":
    main()
