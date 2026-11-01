"""Quant evaluation: `python -m agents quant evaluate` (plan Q11-Q15).

run_evaluate(offline=False, report_dir=None, start=None)
  1. IC section: agents.quant.metrics.evaluate_arm for every arm with OOS
     predictions (lgbm and xgb14 required, xgb_full optional): daily IC /
     Rank-IC, ICIR, naive / Newey-West / non-overlapping t, per-year table,
     top-k (5/10/20) and Q5-Q1 spreads (raw open-to-open labels).
  2. Gate run #1 on the rank universe present in the quant raw store,
     benchmark SPY: xgb_topk and quant_topk (slot sizing; quant_topk's
     baseline xgb_topk). Bars from agents.quant.raw.load_raw (the bars the
     model saw). No legacy parity section (large universe).
  3. Gate run #2 on the Phase 1 universe (offline: AAA, BBB, CCC):
     quant_rank (baseline v2_confluence evaluated in memory, no gate file).
  4. Go (Q15) = every one of:
       lgbm Rank-IC mean >= 0.02           (MIN_RANK_IC)
       lgbm Rank-IC Newey-West t >= 2      (MIN_RANK_IC_T_NW)
       gate quant_rank passed              (the gate AGENT_QUANT_WEIGHT needs)
       quant_topk beats xgb_topk in >= 60 % of folds (pct_folds_beating_baseline)
       real data (nothing synthetic)
     Go only *proposes* AGENT_QUANT_WEIGHT=0.15; config.template.sh keeps 0
     and the user decides.
  Gate start: START, else the first OOS prediction date of lgbm (2018-01-01
  when the predictions start in 2018). Offline runs use bar folds.
  Writes cache/agents/quant/eval/<run_id>/quant_report.json + .html (self
  contained: no JS, no CDN, every dynamic string HTML-escaped, SYNTHETIC
  banner offline) and copies both to REPORT_DIR when given.
Returns {exit, summary}: exit 0 for any valid result (no-go included), 2 when
predictions or the raw store are missing (nothing written).
"""

from __future__ import annotations

import html
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional

import pandas as pd

from agents import __version__
from agents.envelope import utc_now_iso

REQUIRED_ARMS = ("lgbm", "xgb14")
OPTIONAL_ARMS = ("xgb_full",)
BENCHMARK = "SPY"
MIN_RANK_IC = 0.02
MIN_RANK_IC_T_NW = 2.0
MIN_BASELINE_FOLDS = 0.60
PROPOSED_WEIGHT = 0.15
TOPK_SIGNALS = ["xgb_topk", "quant_topk"]
RANK_SIGNALS = ["quant_rank"]

CAVEATS = [
    "Survivorship bias: the universe is a fixed list of today's liquid US large caps; names that were "
    "delisted, acquired or fell out of the index since 2016 are missing, which flatters every long-only result.",
    "One period only (2016 onwards, one market history); no out-of-period confirmation.",
    "Fixed hyperparameters (Qlib's published Alpha158 LightGBM parameters, legacy XGBoost parameters); "
    "no hyperparameter search, so the model trial count is 1.",
    "Several arms (lgbm, xgb14, xgb_full) and signals (quant_topk, xgb_topk, quant_rank) were tested; this "
    "multiple testing is not in the DSR beyond each gate's own grid.",
    "Adjusted prices (adjustment=all, back-adjusted on every dividend and split).",
    "Alpaca SIP daily bars (IEX when SIP is refused); fills at the next open with 10 bp slippage per side.",
    "vectorbt is Apache 2.0 + Commons Clause (free to use, not to sell).",
    "Not financial advice. A go is evidence for proposing a small weight, not a guarantee.",
]


def eval_dir(run_id: Optional[str] = None) -> Path:
    from agents.cache import cache_root

    base = cache_root() / "quant" / "eval"
    return base / run_id if run_id else base


def _crit(value, threshold, op: str) -> Dict[str, Any]:
    if value is None or threshold is None:
        ok = False
    elif op == ">=":
        ok = float(value) >= float(threshold)
    else:
        ok = bool(value) is bool(threshold)
    return {"value": value, "threshold": threshold, "op": op, "passed": bool(ok)}


def go_decision(ic: Dict[str, Any], gates: Dict[str, Dict[str, Any]], synthetic: bool) -> Dict[str, Any]:
    """{go, criteria} per Q15 from the lgbm IC summary and the gate dicts
    (quant_rank, quant_topk)."""
    qr = gates.get("quant_rank") or {}
    qt = gates.get("quant_topk") or {}
    pct = (qt.get("metrics") or {}).get("pct_folds_beating_baseline")
    criteria = {
        "lgbm_rank_ic_mean": _crit((ic or {}).get("rank_ic_mean"), MIN_RANK_IC, ">="),
        "lgbm_rank_ic_t_nw": _crit((ic or {}).get("rank_ic_t_nw"), MIN_RANK_IC_T_NW, ">="),
        "quant_rank_gate_passed": _crit(qr.get("passed") if qr else None, True, "=="),
        "quant_topk_beats_xgb_topk_folds": _crit(pct, MIN_BASELINE_FOLDS, ">="),
        "real_data": _crit(not synthetic, True, "=="),
    }
    go = all(c["passed"] for c in criteria.values()) and not synthetic
    return {"go": bool(go), "criteria": criteria,
            "ic_ok": criteria["lgbm_rank_ic_mean"]["passed"] and criteria["lgbm_rank_ic_t_nw"]["passed"],
            "gate_ok": criteria["quant_rank_gate_passed"]["passed"],
            "baseline_ok": criteria["quant_topk_beats_xgb_topk_folds"]["passed"],
            "quant_topk_passed": bool(qt.get("passed")) if qt else None}


def _gate_start(start: Optional[str], first: Optional[pd.Timestamp]) -> Optional[str]:
    if start:
        return start
    if first is None:
        return None
    if first.year == 2018:
        return "2018-01-01"
    return str(first.date())


def _load_bars(symbols: List[str]):
    from agents.quant import raw

    loaded = raw.load_raw(list(dict.fromkeys(symbols)))
    missing = {s: getattr(r, "reason", "unavailable") for s, r in loaded.items() if not getattr(r, "available", False)}
    return loaded, missing


def _training_summary() -> Optional[Dict[str, Any]]:
    from agents.quant.train import read_latest

    m = read_latest()
    if not m:
        return None
    arms = {}
    for arm, info in (m.get("arms") or {}).items():
        arms[arm] = {"handler": info.get("handler"), "feature_set": info.get("feature_set"),
                     "n_features": info.get("n_features"), "model": info.get("model"),
                     "params": info.get("params"), "folds": len(info.get("folds") or []),
                     "prediction_rows": info.get("prediction_rows"), "seconds": info.get("seconds"),
                     "live_train_end": (info.get("live") or {}).get("train_end")}
    return {"train_run_id": m.get("train_run_id"), "generated_at": m.get("generated_at"), "mode": m.get("mode"),
            "synthetic": m.get("synthetic"), "label": m.get("label"), "embargo": m.get("embargo"),
            "calendar": m.get("calendar"), "versions": m.get("versions"), "arms": arms}


def _data_summary() -> Dict[str, Any]:
    from agents.quant.store import read_store_meta

    meta = read_store_meta() or {}
    counts: Dict[str, int] = {}
    for label in (meta.get("data_sources") or {}).values():
        counts[label] = counts.get(label, 0) + 1
    return {"store_built_at": meta.get("built_at"), "calendar_start": meta.get("calendar_start"),
            "calendar_end": meta.get("calendar_end"), "sessions": meta.get("sessions"),
            "rank_instruments": meta.get("rank_instruments"), "benchmarks": meta.get("benchmarks"),
            "data_sources": counts, "synthetic": bool(meta.get("synthetic"))}


def run_evaluate(offline: bool = False, report_dir: Optional[str] = None, start: Optional[str] = None) -> Dict[str, Any]:
    from agents.quant import metrics as M
    from agents.signals.quant import load_ranks, predictions_file
    from agents.validate.agent import _clean, default_quant_symbols, new_run_id, run_gate
    from agents.validate.universe import default_universe

    preds: Dict[str, pd.DataFrame] = {}
    for arm in REQUIRED_ARMS + OPTIONAL_ARMS:
        path = predictions_file(arm)
        if path.is_file():
            preds[arm] = pd.read_parquet(path)
        elif arm in REQUIRED_ARMS:
            return {"exit": 2, "summary": {"error": "quant_predictions_unavailable", "agent": "quant", "arm": arm,
                                           "detail": "no %s; run `python -m agents quant train` first" % path}}
    rank = default_quant_symbols("quant", offline)
    phase1 = default_universe(offline)
    bars1, miss1 = _load_bars(rank + [BENCHMARK])
    bars2, miss2 = _load_bars(phase1 + [BENCHMARK])
    missing = dict(miss1, **miss2)
    if missing:
        return {"exit": 2, "summary": {"error": "quant_store_unavailable", "agent": "quant", "unavailable": missing,
                                       "detail": "run `python -m agents quant ingest` first; nothing written"}}

    ic_section = {arm: M.evaluate_arm(df) for arm, df in preds.items()}
    first = load_ranks("lgbm").index.min()
    gstart = _gate_start(start, first)

    g1 = run_gate(TOPK_SIGNALS, rank, BENCHMARK, gstart, None, offline, bars_res=bars1, include_parity=False)
    if g1["exit"] != 0:
        return g1
    g2 = run_gate(RANK_SIGNALS, phase1, BENCHMARK, gstart, None, offline, bars_res=bars2)
    if g2["exit"] != 0:
        return g2
    gates = {g["signal_id"]: g for g in g1["gates"] + g2["gates"]}
    data = _data_summary()
    training = _training_summary()
    synthetic = bool(any(g.get("synthetic") for g in gates.values()) or data.get("synthetic")
                     or (training or {}).get("synthetic"))
    decision = go_decision((ic_section.get("lgbm") or {}).get("ic") or {}, gates, synthetic)

    run_id = new_run_id()
    out_dir = eval_dir(run_id)
    report = _clean({
        "run_id": run_id, "generated_at": utc_now_iso(), "agent_version": __version__,
        "mode": "offline" if offline else "real", "synthetic": synthetic,
        "warning": ("Evaluation on SYNTHETIC offline fixtures; it says nothing about real performance and "
                    "can never be a go." if synthetic else None),
        "gate_start": gstart, "universes": {"topk": rank, "quant_rank": phase1, "benchmark": BENCHMARK},
        "data": data, "training": training, "ic": ic_section,
        "gates": {sid: _gate_digest(g) for sid, g in gates.items()},
        "baselines": (g1.get("meta") or {}).get("baselines", []) + (g2.get("meta") or {}).get("baselines", []),
        "gate_reports": {"topk": {"run_id": g1["summary"]["run_id"], "report_html": g1["summary"]["report_html"],
                                  "report_json": g1["summary"]["report_json"]},
                         "quant_rank": {"run_id": g2["summary"]["run_id"],
                                        "report_html": g2["summary"]["report_html"],
                                        "report_json": g2["summary"]["report_json"]}},
        "decision": decision,
        "proposal": ("propose AGENT_QUANT_WEIGHT=%.2f (config default stays 0; user decides)" % PROPOSED_WEIGHT
                     if decision["go"] else None),
        "caveats": CAVEATS,
    })
    paths = write_eval_report(out_dir, report)
    if report_dir:
        dest = Path(report_dir)
        dest.mkdir(parents=True, exist_ok=True)
        for p in paths.values():
            shutil.copy2(p, dest / Path(p).name)
        paths = {k: str(dest / Path(v).name) for k, v in paths.items()}
    summary = {
        "run_id": run_id, "report_html": paths["report_html"], "report_json": paths["report_json"],
        "go": decision["go"], "synthetic": synthetic, "criteria": report["decision"]["criteria"],
        "proposal": report["proposal"],
        "gates": {sid: {"passed": g["passed"], "synthetic": g["synthetic"],
                        "failed_criteria": [k for k, c in g["criteria"].items()
                                            if c.get("applicable") and not c.get("passed")]}
                  for sid, g in gates.items()},
    }
    return {"exit": 0, "summary": summary, "report": report}


def _gate_digest(g: Dict[str, Any]) -> Dict[str, Any]:
    keys = ("signal_id", "passed", "synthetic", "run_id", "description", "universe", "benchmark", "data_range",
            "walk_forward", "metrics", "criteria", "folds", "reasons", "inputs", "data_sources")
    return {k: g.get(k) for k in keys}


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def esc(x: Any) -> str:
    return html.escape("" if x is None else str(x), quote=True)


def _f(x: Any, digits: int = 4) -> str:
    if x is None:
        return "n/a"
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, float):
        return ("%%.%df" % digits) % x
    return str(x)


def _kv_table(rows: List[tuple], tid: Optional[str] = None) -> str:
    out = ['<table%s>' % (' id="%s"' % esc(tid) if tid else "")]
    for k, v in rows:
        if isinstance(v, (list, tuple)):
            v = ", ".join(str(x) for x in v)
        elif isinstance(v, dict):
            v = "; ".join("%s=%s" % (a, b) for a, b in v.items())
        out.append("<tr><th>%s</th><td>%s</td></tr>" % (esc(k), esc(_f(v))))
    out.append("</table>")
    return "".join(out)


def render_eval_html(rep: Dict[str, Any]) -> str:
    o: List[str] = ["<!DOCTYPE html>", '<html lang="en">', "<head>", '<meta charset="utf-8">',
                    "<title>%s</title>" % esc("StockSwingTrader quant evaluation %s" % rep.get("run_id")),
                    "<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;margin:24px;color:#1f2328}"
                    "table{border-collapse:collapse;margin:8px 0 20px}th,td{border:1px solid #d0d7de;"
                    "padding:4px 8px;font-size:13px;text-align:left}th{background:#f6f8fa}.pass{background:#dafbe1}"
                    ".fail{background:#ffebe9}.na{background:#f6f8fa;color:#57606a}"
                    ".banner{background:#ffebe9;border:2px solid #cf222e;padding:10px;font-weight:bold;"
                    "margin:12px 0}</style>", "</head>", "<body>", "<h1>Quant research agent evaluation</h1>"]
    if rep.get("synthetic"):
        o.append('<div class="banner" id="synthetic-banner">SYNTHETIC DATA: offline fixtures (generated). '
                 'These numbers say nothing about real performance; every gate fails by rule and the '
                 'decision is no-go.</div>')
    o.append('<h2 id="run">Run</h2>')
    o.append(_kv_table([("run_id", rep.get("run_id")), ("generated_at", rep.get("generated_at")),
                        ("mode", rep.get("mode")), ("agent_version", rep.get("agent_version")),
                        ("gate_start", rep.get("gate_start")),
                        ("top-k universe size", len((rep.get("universes") or {}).get("topk") or [])),
                        ("quant_rank universe", (rep.get("universes") or {}).get("quant_rank")),
                        ("benchmark", (rep.get("universes") or {}).get("benchmark"))]))
    o.append('<h2 id="data">Data</h2>')
    o.append(_kv_table(list((rep.get("data") or {}).items())))
    o.append('<h2 id="training">Training</h2>')
    tr = rep.get("training") or {}
    o.append(_kv_table([(k, tr.get(k)) for k in ("train_run_id", "generated_at", "mode", "synthetic", "label",
                                                  "embargo", "calendar", "versions")]))
    o.append("<table><tr><th>arm</th><th>features</th><th>model</th><th>folds</th><th>prediction rows</th>"
             "<th>seconds</th><th>live train end</th></tr>")
    for arm, a in (tr.get("arms") or {}).items():
        o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(_f(v)) for v in (
            arm, "%s (%s)" % (a.get("feature_set"), a.get("n_features")), a.get("model"), a.get("folds"),
            a.get("prediction_rows"), a.get("seconds"), a.get("live_train_end"))))
    o.append("</table>")

    o.append('<h2 id="ic">Information coefficient per arm</h2>')
    o.append("<table><tr><th>arm</th><th>dates</th><th>IC mean</th><th>ICIR</th><th>Rank-IC mean</th>"
             "<th>Rank ICIR</th><th>t naive</th><th>t Newey-West</th><th>t non-overlap</th><th>% positive</th></tr>")
    for arm, ev in (rep.get("ic") or {}).items():
        ic = ev.get("ic") or {}
        o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(_f(v)) for v in (
            arm, ic.get("n_days"), ic.get("ic_mean"), ic.get("icir"), ic.get("rank_ic_mean"), ic.get("rank_icir"),
            ic.get("rank_ic_t_naive"), ic.get("rank_ic_t_nw"), ic.get("rank_ic_t_nonoverlap"),
            ic.get("pct_positive"))))
    o.append("</table>")
    for arm, ev in (rep.get("ic") or {}).items():
        o.append("<h3>%s per year</h3>" % esc(arm))
        rows = ev.get("per_year") or []
        cols = list(rows[0].keys()) if rows else []
        o.append("<table><tr>%s</tr>" % "".join("<th>%s</th>" % esc(c) for c in cols))
        for r in rows:
            o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(_f(r.get(c))) for c in cols))
        o.append("</table>")

    o.append('<h2 id="spreads">Top-k and quintile spreads (raw 5-day open-to-open labels)</h2>')
    o.append("<table><tr><th>arm</th><th>portfolio</th><th>mean excess / period</th><th>annualised</th>"
             "<th>t Newey-West</th><th>hit rate</th></tr>")
    for arm, ev in (rep.get("ic") or {}).items():
        for t in (ev.get("topk") or []):
            o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(_f(v)) for v in (
                arm, "top %s" % t.get("k"), t.get("mean_excess"), t.get("annualised"), t.get("t_nw"),
                t.get("hit_rate"))))
        q = ev.get("quintile") or {}
        o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(_f(v)) for v in (
            arm, "Q5 - Q1", q.get("mean_excess"), q.get("annualised"), q.get("t_nw"), q.get("hit_rate"))))
    o.append("</table>")

    o.append('<h2 id="gates">Gates</h2>')
    from agents.validate.gate import CRITERIA

    o.append("<table><tr><th>signal</th><th>passed</th>%s</tr>" % "".join("<th>%s</th>" % esc(c) for c in CRITERIA))
    for sid, g in (rep.get("gates") or {}).items():
        cells = []
        for c in CRITERIA:
            cr = (g.get("criteria") or {}).get(c) or {}
            if not cr.get("applicable", True):
                cells.append('<td class="na">n/a</td>')
                continue
            cells.append('<td class="%s">%s %s %s<br>%s</td>' % (
                "pass" if cr.get("passed") else "fail", esc(_f(cr.get("value"))), esc(cr.get("op")),
                esc(_f(cr.get("threshold"))), "PASS" if cr.get("passed") else "FAIL"))
        o.append('<tr><td>%s</td><td class="%s">%s</td>%s</tr>' % (
            esc(sid), "pass" if g.get("passed") else "fail", "PASSED" if g.get("passed") else "FAILED",
            "".join(cells)))
    o.append("</table>")
    for sid, g in (rep.get("gates") or {}).items():
        o.append("<h3>%s</h3><p>%s</p><p>Reasons: %s</p>" % (
            esc(sid), esc(g.get("description")), esc("; ".join(g.get("reasons") or []) or "none")))
        o.append("<table><tr><th>fold</th><th>train</th><th>test</th><th>params</th><th>OOS Sharpe</th>"
                 "<th>OOS return</th><th>baseline return</th><th>SPY return</th><th>trades</th></tr>")
        for f in g.get("folds") or []:
            params = ", ".join("%s=%s" % kv for kv in sorted((f.get("params") or {}).items()))
            o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(v) for v in (
                f.get("fold"), " .. ".join(f.get("train") or []), " .. ".join(f.get("test") or []), params,
                _f(f.get("oos_sharpe")), _f(f.get("oos_return")), _f(f.get("baseline_return")),
                _f(f.get("spy_return")), f.get("trades"))))
        o.append("</table>")
    if rep.get("baselines"):
        o.append('<h3 id="baselines">Baselines (evaluated in memory, no gate file)</h3>')
        o.append("<table><tr><th>baseline</th><th>for</th><th>would pass</th><th>OOS Sharpe</th>"
                 "<th>fold OOS returns</th></tr>")
        for b in rep["baselines"]:
            o.append("<tr>%s</tr>" % "".join("<td>%s</td>" % esc(v) for v in (
                b.get("signal_id"), b.get("for"), _f(b.get("would_pass")),
                _f((b.get("metrics") or {}).get("oos_sharpe")),
                ", ".join(_f(f.get("oos_return")) for f in b.get("folds") or []))))
        o.append("</table>")
    gr = rep.get("gate_reports") or {}
    o.append("<p>Gate run reports: %s</p>" % esc("; ".join("%s: %s" % (k, (v or {}).get("report_html"))
                                                         for k, v in gr.items())))

    d = rep.get("decision") or {}
    o.append('<h2 id="go">Go / no-go</h2>')
    o.append('<p class="%s" id="decision">%s</p>' % ("pass" if d.get("go") else "fail",
                                                     "GO" if d.get("go") else "NO-GO"))
    o.append("<table><tr><th>criterion</th><th>value</th><th>rule</th><th>result</th></tr>")
    for name, c in (d.get("criteria") or {}).items():
        o.append('<tr><td>%s</td><td>%s</td><td>%s %s</td><td class="%s">%s</td></tr>' % (
            esc(name), esc(_f(c.get("value"))), esc(c.get("op")), esc(_f(c.get("threshold"))),
            "pass" if c.get("passed") else "fail", "PASS" if c.get("passed") else "FAIL"))
    o.append("</table>")
    if rep.get("proposal"):
        o.append('<p id="proposal">%s</p>' % esc(rep["proposal"]))
    else:
        o.append("<p>No weight is proposed; AGENT_QUANT_WEIGHT stays 0.</p>")
    o.append('<h2 id="caveats">Caveats</h2><ul>')
    for c in rep.get("caveats") or []:
        o.append("<li>%s</li>" % esc(c))
    o.append("</ul>")
    o.append("</body>")
    o.append("</html>")
    return "\n".join(o) + "\n"


def write_eval_report(out_dir: Path, rep: Dict[str, Any]) -> Dict[str, str]:
    import os
    import tempfile

    from agents.cache import atomic_write_json

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    jpath = atomic_write_json(out_dir / "quant_report.json", rep)
    hpath = out_dir / "quant_report.html"
    fd, tmp = tempfile.mkstemp(dir=str(out_dir), prefix=".quant_report.html.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(render_eval_html(rep))
        os.replace(tmp, hpath)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise
    return {"report_json": str(jpath), "report_html": str(hpath)}


def latest_evaluation() -> Optional[Dict[str, Any]]:
    """{run_id, generated_at, go, synthetic, report_html} of the newest eval run."""
    from agents.cache import read_json

    base = eval_dir()
    if not base.is_dir():
        return None
    for d in sorted((p for p in base.iterdir() if p.is_dir()), key=lambda p: p.name, reverse=True):
        rep = read_json(d / "quant_report.json")
        if isinstance(rep, dict):
            return {"run_id": rep.get("run_id"), "generated_at": rep.get("generated_at"),
                    "go": (rep.get("decision") or {}).get("go"), "synthetic": rep.get("synthetic"),
                    "report_html": str(d / "quant_report.html")}
    return None
