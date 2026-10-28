        for s in d["top"][:5]:
            ax.plot(s[2] / 1e9, s[0] / 1000.0, marker="v", color=c, markersize=5)
    if args.deadline:
        ax.axhline(args.deadline, color="red", linewidth=1.5)
    ax.set_yscale("log")
    win = runs[0]["window_ns"] / 1e6
    ax.set_xlabel(f"temps depuis le début de la mesure (s) — fenêtres de {win:.2f} ms, ▼ = 5 pires échantillons")
    ax.set_ylabel(x_label(runs))
    ax.set_title("Évolution dans le temps (un pic régulier = une cause périodique)")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=7, ncol=2, loc="upper right")


# --------------------------------------------------------------------------
def summary_line(d, lab, deadline):
    p = d["percentiles"]
    s = (f"{lab}: n={d['count']}  min {fmt_us(d['min_ns'] / 1000)}  moy {fmt_us(d['avg_ns'] / 1000)}  "
         f"p99 {fmt_us(p['99'] / 1000)}  p99.99 {fmt_us(p['99.99'] / 1000)}  max {fmt_us(d['max_ns'] / 1000)}")
    if deadline:
        over = d["_n"][d["_lo"] >= deadline].sum()
        s += f"  > budget : {int(over)} ({over / max(d['count'], 1) * 100:.4f} %)"
    return s


def main():
    ap = argparse.ArgumentParser(description="Tracés de latence pour les JSON de rtlat")
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--output")
    ap.add_argument("--labels")
    ap.add_argument("--logx", action="store_true")
    ap.add_argument("--xmax", type=float)
    ap.add_argument("--deadline", type=float)
    ap.add_argument("--gauss", action="store_true")
    ap.add_argument("--title")
    args = ap.parse_args()
