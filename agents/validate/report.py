"""Validation report: report.json + self-contained report.html (plan D22).

report.json  run metadata, every gate dict, the OOS equity curves and the
             legacy parity summary (when available)
report.html  no JS, no CDN, no external resources; every dynamic string goes
             through html.escape. Summary table (signal, passed, each
             criterion value / threshold with a PASS / FAIL / n/a cell), a
             fold table per signal, an inline SVG polyline chart of the pooled
             OOS equity (strategy vs SPY vs equal weight), a SYNTHETIC banner
             when any input is synthetic, and the caveats list.
Default directory: cache/agents/validate/reports/<run_id>/ (or --report-dir).
"""

from __future__ import annotations

import html
from pathlib import Path
from typing import Any, Dict, List, Optional

from agents.cache import atomic_write_json, cache_root

CAVEATS = [
    "Survivorship bias: the universe is a fixed list of today's large caps; delisted or "
    "shrunk companies are missing, which flatters every long-only result.",
    "The ML component is excluded from the v2 replay: the XGBoost model is trained on synthetic "
    "data and would leak; ML weight is renormalised away (35/30/20 over 85).",
    "Sentiment is excluded (no historical news sentiment); MiroFish and the agent layer are off.",
    "Fills are at the next bar's open after the signal bar; stops and take profits trigger "
    "intrabar from the daily high/low (not on the entry bar itself; stop first when a stop and "
    "a signal exit share a bar).",
    "Cost assumptions: slippage per side as listed (incl. spread), zero commission; no borrow, "
    "no taxes, no market impact beyond slippage.",
    "Daily bars only; adjusted prices as delivered by the data source.",
    "Not financial advice. A passed gate is evidence, not a guarantee; a failed gate means no "
    "live money for that signal.",
]


def esc(x: Any) -> str:
    return html.escape("" if x is None else str(x), quote=True)


def _fmt(x: Any, digits: int = 3) -> str:
    if x is None:
        return "n/a"
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, float):
        return ("%%.%df" % digits) % x
    return str(x)


def report_dir(run_id: str, override: Optional[str] = None) -> Path:
    if override:
        return Path(override)
    return cache_root() / "validate" / "reports" / run_id


def svg_chart(curves: Dict[str, List[float]], width: int = 720, height: int = 220) -> str:
    """Inline SVG with one polyline per named curve (values are equity
    multiples starting near 1)."""
    colors = {"strategy": "#1f6feb", "spy": "#d29922", "equal_weight": "#2da44e"}
    series = {k: [float(v) for v in vals if v is not None] for k, vals in curves.items() if vals}
    if not series:
        return "<p>No out-of-sample equity curve.</p>"
    lo = min(min(v) for v in series.values())
    hi = max(max(v) for v in series.values())
    if hi - lo < 1e-9:
        hi, lo = lo + 0.5, lo - 0.5
    pad = 20
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
             'role="img" aria-label="Out-of-sample equity curves">' % (width, height, width, height),
             '<rect x="0" y="0" width="%d" height="%d" fill="#ffffff" stroke="#d0d7de"/>' % (width, height)]
    for name, vals in series.items():
        n = len(vals)
        pts = []
        for i, v in enumerate(vals):
            x = pad + (width - 2 * pad) * (i / max(n - 1, 1))
            y = height - pad - (height - 2 * pad) * ((v - lo) / (hi - lo))
            pts.append("%.1f,%.1f" % (x, y))
        parts.append('<polyline fill="none" stroke="%s" stroke-width="1.5" points="%s"/>'
                     % (colors.get(name, "#57606a"), " ".join(pts)))
    ly = 14
    for name in series:
        parts.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'
                     % (pad + 4, ly, colors.get(name, "#57606a"), esc(name)))
        ly += 13
    parts.append('<text x="%d" y="%d" font-size="10" fill="#57606a" text-anchor="end">max %s / min %s</text>'
                 % (width - pad, 14, esc("%.3f" % hi), esc("%.3f" % lo)))
    parts.append("</svg>")
    return "".join(parts)


def _criteria_header(gates: List[Dict[str, Any]]) -> List[str]:
    from agents.validate.gate import CRITERIA

    return list(CRITERIA)


def render_html(meta: Dict[str, Any], gates: List[Dict[str, Any]], curves: Dict[str, Dict[str, List[float]]],
                parity: Optional[Dict[str, Any]] = None) -> str:
    synthetic = bool(meta.get("synthetic")) or any(g.get("synthetic") for g in gates)
    crit_names = _criteria_header(gates)
    out: List[str] = []
    out.append("<!DOCTYPE html>")
    out.append('<html lang="en">')
    out.append("<head>")
    out.append('<meta charset="utf-8">')
    out.append("<title>%s</title>" % esc("StockSwingTrader validation report %s" % meta.get("run_id", "")))
    out.append("<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;margin:24px;color:#1f2328}"
               "table{border-collapse:collapse;margin:8px 0 20px}th,td{border:1px solid #d0d7de;padding:4px 8px;"
               "font-size:13px;text-align:left}th{background:#f6f8fa}.pass{background:#dafbe1}"
               ".fail{background:#ffebe9}.na{background:#f6f8fa;color:#57606a}"
               ".banner{background:#ffebe9;border:2px solid #cf222e;padding:10px;font-weight:bold;margin:12px 0}"
               "code{font-size:12px}</style>")
    out.append("</head>")
    out.append("<body>")
    out.append("<h1>Strategy validation report</h1>")
    if synthetic:
        out.append('<div class="banner" id="synthetic-banner">SYNTHETIC DATA: at least one input is '
                   'synthetic (offline fixtures). These results say nothing about real performance and '
                   'every gate is failed by rule.</div>')
    out.append("<h2>Run</h2>")
    out.append("<table>")
    for key in ("run_id", "generated_at", "mode", "universe", "benchmark", "data_range", "data_sources",
                "walk_forward", "costs", "agent_version"):
        val = meta.get(key)
        if isinstance(val, (list, tuple)):
            val = ", ".join(str(v) for v in val)
        elif isinstance(val, dict):
            val = "; ".join("%s=%s" % (k, v) for k, v in val.items())
        out.append("<tr><th>%s</th><td>%s</td></tr>" % (esc(key), esc(val)))
    out.append("</table>")

    out.append("<h2>Summary</h2>")
    out.append('<table id="summary">')
    out.append("<tr><th>signal</th><th>passed</th>%s</tr>" % "".join("<th>%s</th>" % esc(c) for c in crit_names))
    for g in gates:
        cells = []
        for c in crit_names:
            cr = (g.get("criteria") or {}).get(c) or {}
            if not cr.get("applicable", True):
                cells.append('<td class="na">n/a</td>')
                continue
            cls = "pass" if cr.get("passed") else "fail"
            cells.append('<td class="%s">%s %s %s<br>%s</td>' % (
                cls, esc(_fmt(cr.get("value"))), esc(cr.get("op")), esc(_fmt(cr.get("threshold"))),
                "PASS" if cr.get("passed") else "FAIL"))
        out.append('<tr><td>%s</td><td class="%s">%s</td>%s</tr>' % (
            esc(g.get("signal_id")), "pass" if g.get("passed") else "fail",
            "PASSED" if g.get("passed") else "FAILED", "".join(cells)))
    out.append("</table>")

    for g in gates:
        sid = g.get("signal_id")
        m = g.get("metrics") or {}
        out.append('<h2 id="%s">%s</h2>' % (esc("signal-%s" % sid), esc(sid)))
        if g.get("description"):
            out.append("<p>%s</p>" % esc(g.get("description")))
        out.append("<p>Reasons: %s</p>" % esc("; ".join(g.get("reasons") or []) or "none"))
        out.append("<table>")
        for k in ("oos_sharpe", "oos_cagr", "oos_max_dd", "oos_trades", "oos_days", "pct_positive_folds",
                  "spy_sharpe", "spy_cagr", "spy_max_dd", "ew_sharpe", "ew_cagr", "ew_max_dd", "dsr", "psr",
                  "pbo", "pbo_S", "n_trials", "grid_size", "n_evaluations"):
            if k in m:
                out.append("<tr><th>%s</th><td>%s</td></tr>" % (esc(k), esc(_fmt(m.get(k), 4))))
        out.append("</table>")
        out.append("<table>")
        out.append("<tr><th>fold</th><th>train</th><th>test</th><th>params</th><th>train Sharpe</th>"
                   "<th>OOS Sharpe</th><th>OOS return</th><th>SPY return</th><th>EW return</th><th>trades</th></tr>")
        for f in g.get("folds") or []:
            params = ", ".join("%s=%s" % (k, v) for k, v in sorted((f.get("params") or {}).items()))
            out.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
                       "<td>%s</td><td>%s</td><td>%s</td></tr>" % (
                           esc(f.get("fold")), esc(" .. ".join(f.get("train") or [])),
                           esc(" .. ".join(f.get("test") or [])), esc(params), esc(_fmt(f.get("train_sharpe"))),
                           esc(_fmt(f.get("oos_sharpe"))), esc(_fmt(f.get("oos_return"))),
                           esc(_fmt(f.get("spy_return"))), esc(_fmt(f.get("ew_return"))), esc(f.get("trades"))))
        out.append("</table>")
        out.append(svg_chart((curves or {}).get(sid) or {}))

    if parity:
        out.append("<h2>Legacy parity (lib/backtest_engine.py vs vectorbt)</h2>")
        out.append("<p>%s</p>" % esc("ok" if parity.get("ok") else "MISMATCH"))
        out.append("<table><tr><th>symbol</th><th>strategy</th><th>legacy trades</th><th>vectorbt trades</th>"
                   "<th>legacy P&amp;L</th><th>vectorbt P&amp;L</th><th>ok</th></tr>")
        for r in parity.get("results") or []:
            out.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                esc(r.get("symbol")), esc(r.get("strategy")), esc(r.get("legacy_trades")),
                esc(r.get("vbt_trades")), esc(_fmt(r.get("legacy_pnl"), 2)), esc(_fmt(r.get("vbt_pnl"), 2)),
                esc("yes" if r.get("ok") else "no")))
        out.append("</table>")

    out.append("<h2>Caveats</h2>")
    out.append("<ul>")
    for c in CAVEATS + list(meta.get("notes") or []):
        out.append("<li>%s</li>" % esc(c))
    out.append("</ul>")
    out.append("</body>")
    out.append("</html>")
    return "\n".join(out) + "\n"


def write_report(out_dir: Path, meta: Dict[str, Any], gates: List[Dict[str, Any]],
                 curves: Dict[str, Dict[str, List[float]]], parity: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    """Write report.json and report.html into OUT_DIR; returns their paths."""
    import os
    import tempfile

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    jpath = atomic_write_json(out_dir / "report.json",
                              {"meta": meta, "gates": gates, "curves": curves, "legacy_parity": parity})
    hpath = out_dir / "report.html"
    fd, tmp = tempfile.mkstemp(dir=str(out_dir), prefix=".report.html.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(render_html(meta, gates, curves, parity))
        os.replace(tmp, hpath)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    return {"report_json": str(jpath), "report_html": str(hpath)}
