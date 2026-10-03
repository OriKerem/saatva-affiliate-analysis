"""Charts for the README (docs/img/), from the full-run outputs. Run after the pipeline."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs"
IMG = ROOT / "docs" / "img"

INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e6e4df", "#ffffff"
AMBER, BLUE, VIOLET = "#B7791F", "#2E86C1", "#6C3FA0"   # colorblind-safe set
SEQ = ["#1E5FA8", "#2E86C1", "#8DB8E0"]

LABELS = {"saatva": "Saatva", "nectar": "Nectar", "helix": "Helix", "dreamcloud": "DreamCloud",
          "walmart_mattress": "Walmart - mattresses", "walmart_all": "Walmart - all (context)"}

plt.rcParams.update({"font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.titlesize": 12,
                     "axes.titleweight": "bold", "axes.titlecolor": INK, "figure.facecolor": SURFACE,
                     "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE})


def tidy(ax, grid_axis="x"):
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(length=0)


def fmt_clicks(v):
    """1,700 / 27,400 / 1.39 M"""
    if v >= 1e6:
        return f"{v / 1e6:.2f} M"
    return f"{round(v, -2 if v >= 1000 else -1):,.0f}"


def us_clicks():
    d = pd.read_csv(OUT / "05b_mattress_comparison" / "mattress_comparison.csv")
    order = ["saatva", "nectar", "helix", "dreamcloud", "walmart_mattress", "walmart_all"]
    d = d.set_index("segment").loc[order].iloc[::-1]
    fig, ax = plt.subplots(figsize=(8, 3.6))
    y = range(len(d))
    for i, (seg, r) in enumerate(d.iterrows()):
        col = AMBER if seg == "saatva" else BLUE
        ax.plot([r.us_clicks_lo, r.us_clicks_hi], [i, i], color=col, linewidth=2, solid_capstyle="round")
        ax.plot(r.us_clicks_per_day, i, "o", color=col, markersize=8, markeredgecolor=SURFACE, markeredgewidth=1.5)
        ax.text(r.us_clicks_hi * 1.15, i, "≈ " + fmt_clicks(r.us_clicks_per_day), va="center", fontsize=9, color=INK)
    ax.set_yticks(list(y), [LABELS[s] for s in d.index])
    ax.set_xscale("log")
    ax.set_xlim(60, 8e6)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("US affiliate clicks per day (log scale); line = 95% range")
    ax.set_title("Affiliate volume: Saatva is in the same range as its direct rivals", loc="left")
    tidy(ax)
    fig.tight_layout()
    fig.savefig(IMG / "us_clicks.png", dpi=160)
    plt.close(fig)


def channel_mix():
    d = pd.read_csv(OUT / "07_competitive_benchmark" / "channel_mix_wide.csv").set_index("segment")
    order = ["saatva", "nectar", "helix", "dreamcloud", "walmart_mattress"]
    d = d.loc[order]
    series = [("pct_affiliate", "Affiliate", AMBER), ("pct_paid_search", "Paid search", BLUE),
              ("pct_from_competitor", "Right after a competitor's site", VIOLET)]
    fig, ax = plt.subplots(figsize=(8, 4.1))
    w, gap = 0.26, 0.02
    for k, (col, name, color) in enumerate(series):
        xs = [i + (k - 1) * (w + gap) for i in range(len(d))]
        vals = d[col].tolist()
        ax.bar(xs, vals, width=w, color=color, label=name)
        for x, v in zip(xs, vals):
            if v > 0:
                ax.text(x, v + 1, f"{v:.1f}%", ha="center", va="bottom", fontsize=7.5, color=INK)
    ax.set_xticks(range(len(d)), [LABELS[s] for s in d.index])
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0f}%"))
    ax.set_ylim(0, 58)
    ax.set_ylabel("Share of visits (mattress shoppers)")
    ax.set_title("How shoppers enter each brand: Saatva leans on affiliates most", loc="left")
    ax.legend(frameon=False, ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.1), fontsize=9)
    tidy(ax, "y")
    ax.spines["bottom"].set_visible(True)
    fig.tight_layout()
    fig.savefig(IMG / "channel_mix.png", dpi=160)
    plt.close(fig)


def walmart_hijacking():
    r = pd.read_csv(OUT / "06_hijacking" / "commission_at_risk.csv").set_index("brand").loc["walmart"]
    rows = [("Strong evidence", r.pct_strong, r.strong, "ad + affiliate tag on one URL, stand-down broken, or tag < 60 s before paying"),
            ("Hijacking definition", r.pct_hijack_definition, r.hijack_definition, "+ social tag, or tag added mid-visit"),
            ("Any signal (upper bound)", r.pct_any_signal, r.any_signal, "+ extension, or another publisher just before")]
    fig, ax = plt.subplots(figsize=(8, 3.0))
    for i, (name, pct, n, cap) in enumerate(rows):
        y = len(rows) - 1 - i
        ax.barh(y, pct, height=0.42, color=SEQ[i])
        ax.text(pct + 0.8, y, f"{pct:.1f}%  ({int(n)})", va="center", fontsize=10, color=INK, fontweight="bold")
        ax.text(0, y - 0.38, cap, va="center", fontsize=8, color=INK2)
    ax.set_yticks(range(len(rows)), [r_[0] for r_ in rows][::-1])
    ax.set_xlim(0, 65)
    ax.set_ylim(-0.75, len(rows) - 0.5)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0f}%"))
    ax.set_title(f"Walmart: hijacking signals on {int(r.purchases_credited)} affiliate-credited purchases", loc="left")
    tidy(ax)
    fig.tight_layout()
    fig.savefig(IMG / "walmart_hijacking.png", dpi=160)
    plt.close(fig)


def pipeline():
    """Pipeline diagram."""
    from matplotlib.patches import FancyBboxPatch
    fig, ax = plt.subplots(figsize=(10, 4.2))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 42.2)
    ax.axis("off")

    def node(x, y, w, h, step, title, lines, accent=False):
        edge = AMBER if accent else "#9aa3ad"
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
                                    facecolor="#f7f8fa", edgecolor=edge, linewidth=1.2))
        ax.text(x + 1.6, y + h - 2.2, step, fontsize=8, color=INK2, va="top")
        ax.text(x + 1.6, y + h - 5.4, title, fontsize=10, color=INK, fontweight="bold", va="top")
        ax.text(x + 1.6, y + h - 9.4, "\n".join(lines), fontsize=7.6, color=INK2, va="top", linespacing=1.35)

    def arrow(x0, y0, x1, y1):
        ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                    arrowprops=dict(arrowstyle="-|>", color="#9aa3ad", lw=1.2, shrinkA=0, shrinkB=0))

    W, H, Y = 16, 17, 13
    main = [("Step 00", "Stage", ["12 GB Parquet,", "read once; brand", "users kept"]),
            ("Steps 01-02", "Discover", ["URL parameters", "and values that", "mark a click"]),
            ("Step 03", "Affiliate clicks", ["30-min merge;", "duplicate IDs", "removed"]),
            ("Step 04", "Conversions", ["page-path tiers;", "last click,", "same day"])]
    xs = [0.5, 19.5, 38.5, 57.5]
    for x, (st, t, ls) in zip(xs, main):
        node(x, Y, W, H, st, t, ls)
    for a, b in zip(xs[:-1], xs[1:]):
        arrow(a + W, Y + H / 2, b, Y + H / 2)

    side = [("Step 05", "US estimates", ["x 428 per person,", "95% ranges"]),
            ("Step 06", "Hijacking", ["7 signals,", "3 evidence tiers"]),
            ("Step 07", "Benchmark", ["channels, publishers,", "scorecard"])]
    sx, sw, sh = 80, 19, 13.4
    for i, (st, t, ls) in enumerate(side):
        y = 28.3 - i * 14.0
        node(sx, y, sw, sh, st, t, ls)
        arrow(xs[-1] + W, Y + H / 2, sx, y + sh / 2)

    ax.text(0.5, 6, "One SQL pipeline (DuckDB): the same code runs on synthetic data,\na dev sample and the full data.",
            fontsize=8.5, color=INK2, va="top")
    fig.tight_layout(pad=0.4)
    fig.savefig(IMG / "pipeline.png", dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    IMG.mkdir(parents=True, exist_ok=True)
    us_clicks()
    channel_mix()
    walmart_hijacking()
    pipeline()
    print("charts written to", IMG)
