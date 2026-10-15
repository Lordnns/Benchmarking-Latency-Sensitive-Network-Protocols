#!/usr/bin/env python3
"""
plot_jitter.py — Per-run unreliable stream jitter scatter.

Reads per-run JSON files produced by:

    for csv in benchmark_results/validation_*/quic_run*.csv; do
        ./target/release/stats "$csv" > "${csv%.csv}.json"
    done

Add as many result folders as you like — each folder becomes one series:

    python3 scripts/plot_jitter.py \\
        --run benchmark_results/validation_optimized_YYYYMMDD_HHMMSS \\
        --run benchmark_results/validation_unoptimized_veth_YYYYMMDD_HHMMSS \\
        --run "Loopback=benchmark_results/validation_unoptimized_lo_YYYYMMDD_HHMMSS" \\
        --out benchmark_results/figures/jitter_all.svg

The series label defaults to a cleaned-up folder name; override it with the
"Label=path" form. Legacy flags still work:
    --optimized DIR   --unoptimized DIR   --monitored DIR

Scale:  auto (log if the series span >~30x, else linear); force with --logy / --linear.

Requirements:  pip install matplotlib
"""

import argparse
import json
import math
import os
import re
import sys
from glob import glob

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    from matplotlib.lines import Line2D
except ImportError:
    print("ERROR: matplotlib not found.  pip install matplotlib")
    sys.exit(1)

# ── Style palette (cycled across series in order) ─────────────────────────────

PALETTE = [
    {"color": "#0f766e", "facecolor": "#99f6e4", "marker": "s"},  # teal   square
    {"color": "#b91c1c", "facecolor": "#fca5a5", "marker": "o"},  # red    circle
    {"color": "#1d4ed8", "facecolor": "#93c5fd", "marker": "D"},  # blue   diamond
    {"color": "#b45309", "facecolor": "#fcd34d", "marker": "^"},  # amber  triangle
    {"color": "#6d28d9", "facecolor": "#ddd6fe", "marker": "v"},  # purple tri-down
    {"color": "#15803d", "facecolor": "#bbf7d0", "marker": "P"},  # green  plus
    {"color": "#be185d", "facecolor": "#fbcfe8", "marker": "X"},  # pink   x
    {"color": "#0e7490", "facecolor": "#a5f3fc", "marker": "<"},  # cyan   tri-left
    {"color": "#c2410c", "facecolor": "#fed7aa", "marker": ">"},  # orange tri-right
    {"color": "#334155", "facecolor": "#cbd5e1", "marker": "h"},  # slate  hexagon
]

# ── Helpers ───────────────────────────────────────────────────────────────────

def load_jitter(directory: str) -> list[float]:
    """Return per-run unreliable stream jitter values (µs) from a result dir."""
    files = sorted(glob(os.path.join(directory, "quic_run*.json")))
    if not files:
        print(f"  WARNING: no quic_run*.json in {directory} (did you run process_results.sh?)")
        return []

    values = []
    for f in files:
        try:
            with open(f) as fh:
                data = json.load(fh)
            for stream in data.get("streams", []):
                if stream["stream_type"] == "Unreliable":
                    values.append(stream["stats"]["latency"]["jitter_us"])
                    break
        except Exception as e:
            print(f"  WARNING: {f}: {e}")

    print(f"  {len(values)} runs  ← {directory}")
    return values


def clean_label(path: str) -> str:
    """Derive a readable series label from a result folder name."""
    name = os.path.basename(os.path.normpath(path))
    name = re.sub(r"^validation_", "", name)
    name = re.sub(r"_\d{8}_\d{6}$", "", name)   # strip trailing timestamp
    return name.replace("_", " ").strip() or name


def resolve_dir(spec: str, roots: list[str]) -> str:
    """Turn a path OR a bare folder name into an existing directory.

    Resolution order:
      1. If `spec` is already a directory, use it as-is.
      2. Look for `<root>/<spec>` under each search root (friendly name, e.g.
         'validation_optimized_bare' under 'Extracted Data').
      3. Fall back to a glob `<root>/*<spec>*` (e.g. a timestamped folder);
         a single match wins, multiple matches are reported as ambiguous.
    """
    if os.path.isdir(spec):
        return spec
    for root in roots:
        cand = os.path.join(root, spec)
        if os.path.isdir(cand):
            return cand
    matches = []
    for root in roots:
        matches += [m for m in glob(os.path.join(root, f"*{spec}*")) if os.path.isdir(m)]
    matches = sorted(set(matches))
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        print(f"ERROR: '{spec}' is ambiguous across roots {roots}:")
        for m in matches:
            print(f"    {m}")
        sys.exit(1)
    print(f"ERROR: could not find '{spec}'. Searched roots: {roots}")
    sys.exit(1)


def mean(v):
    return sum(v) / len(v) if v else 0.0


def stddev(v):
    if len(v) < 2:
        return 0.0
    m = mean(v)
    return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1))


def fmt_us(v):
    return f"{v/1000:.1f} ms" if v >= 1000 else f"{v:.1f} µs"


# ── Plot ──────────────────────────────────────────────────────────────────────

def plot(series: list[tuple[str, str]], out_path: str, scale: str,
         legend: str = "best"):
    """series = list of (label, directory)."""
    fig, ax = plt.subplots(figsize=(6.6, 4.0))
    legend_handles = []
    all_jitter = []

    # Assign a unique color+marker per series by position. Colours are unique up
    # to len(PALETTE); beyond that the marker changes so combos stay distinct.
    plotted = 0
    for i, (label, directory) in enumerate(series):
        jitter = load_jitter(directory)
        if not jitter:
            continue
        all_jitter.extend(jitter)

        base = PALETTE[plotted % len(PALETTE)]
        style = dict(base)
        if plotted >= len(PALETTE):
            # second lap: keep colour, swap to an alternate marker to stay distinct
            alt = ["*", "8", "p", "d", "H"][(plotted // len(PALETTE) - 1) % 5]
            style["marker"] = alt
        plotted += 1

        run_nums = list(range(1, len(jitter) + 1))
        m, s = mean(jitter), stddev(jitter)
        full_label = f"{label}  (x̄ = {fmt_us(m)}  σ = {fmt_us(s)})"

        ax.scatter(
            run_nums, jitter,
            marker=style["marker"], s=30,
            color=style["facecolor"], edgecolors=style["color"],
            linewidths=0.9, zorder=3,
        )
        legend_handles.append(
            Line2D([0], [0], marker=style["marker"], color="none",
                   markerfacecolor=style["facecolor"],
                   markeredgecolor=style["color"], markersize=6.5,
                   label=full_label)
        )

    if not all_jitter:
        print("ERROR: no data plotted (all folders empty or missing JSON).")
        sys.exit(1)

    # Decide scale
    lo = min(v for v in all_jitter if v > 0)
    hi = max(all_jitter)
    if scale == "auto":
        scale = "log" if hi / lo > 30 else "linear"

    if scale == "log":
        ax.set_yscale("log")
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    else:
        ax.set_yscale("linear")
        ax.set_ylim(bottom=0, top=hi * 1.15)   # 15% head room so top marker isn't clipped
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))

    ax.set_xlabel("Run number", fontsize=9)
    ax.set_ylabel("Jitter (µs)", fontsize=9)
    ax.yaxis.grid(True, which="major", linestyle="--", linewidth=0.4,
                  color="#cccccc", zorder=0)
    ax.xaxis.grid(True, linestyle="--", linewidth=0.4, color="#cccccc", zorder=0)
    ax.set_axisbelow(True)
    ax.spines[["top", "right"]].set_visible(False)
    if legend == "outside":
        # many series: park the legend to the right so it never hides markers
        fig.set_size_inches(9.6, 4.0)
        ax.legend(handles=legend_handles, fontsize=7.5, frameon=True,
                  framealpha=0.92, edgecolor="#dddddd",
                  loc="center left", bbox_to_anchor=(1.01, 0.5))
    else:
        ax.legend(handles=legend_handles, fontsize=7.5, frameon=True,
                  framealpha=0.92, edgecolor="#dddddd", loc="best")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    fig.tight_layout()
    fig.savefig(out_path, format="svg", bbox_inches="tight")
    plt.close(fig)
    print(f"\nSaved ({scale} y-axis) → {out_path}")

# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_run(spec: str) -> tuple[str, str]:
    """'Label=path' → (label, path);  'path' → (clean_label(path), path)."""
    if "=" in spec:
        label, path = spec.split("=", 1)
        return label.strip(), path.strip()
    return clean_label(spec), spec


def main():
    p = argparse.ArgumentParser(description="Per-run jitter scatter for any number of result folders.")
    p.add_argument("--run", action="append", default=[], metavar="[LABEL=]DIR",
                   help="A result folder to plot as one series. Repeatable.")
    # legacy convenience flags
    p.add_argument("--unoptimized")
    p.add_argument("--optimized")
    p.add_argument("--monitored")
    p.add_argument("--root", action="append", default=[], metavar="DIR",
                   help="Search root for resolving bare folder names. Repeatable. "
                        "Default: benchmark_results, 'Extracted Data', .")
    p.add_argument("--out", default="benchmark_results/figures/jitter_scatter.svg")
    p.add_argument("--legend", choices=["best", "outside"], default="best",
                   help="Legend placement: 'best' inside the axes (default) or "
                        "'outside' to the right (useful with many series).")
    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--logy", action="store_true", help="Force logarithmic y-axis.")
    grp.add_argument("--linear", action="store_true", help="Force linear y-axis.")
    args = p.parse_args()

    roots = args.root or ["benchmark_results", "Extracted Data", "."]

    series: list[tuple[str, str]] = []
    for spec in args.run:
        label, path = parse_run(spec)
        series.append((label, resolve_dir(path, roots)))
    for label, path in (("Unoptimized", args.unoptimized),
                        ("Optimized", args.optimized),
                        ("Optimized + Monitored", args.monitored)):
        if path:
            series.append((label, resolve_dir(path, roots)))

    if not series:
        print("ERROR: no folders given. Use --run [LABEL=]DIR (repeatable) or the "
              "legacy --optimized/--unoptimized/--monitored flags.")
        sys.exit(1)

    scale = "log" if args.logy else "linear" if args.linear else "auto"
    plot(series, args.out, scale, args.legend)


if __name__ == "__main__":
    main()
