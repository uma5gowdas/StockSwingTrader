#!/bin/bash
# ============================================================================
# Agents: Parity vs bash (venv suite, offline, no network)
# ============================================================================
# (a) TA-Lib vs the bash indicators (lib/indicators.sh) on AAA/BBB/CCC x 3
#     60-bar windows, on matching definitions, absolute tolerances:
#     RSI <= 0.05; EMA12/26 vs talib.EMA <= 0.05; bash MACD line vs
#     talib.EMA12 - talib.EMA26 <= 0.1; bash histogram == 0 (pins the known
#     signal == macd quirk; talib's MACD signal is only reported); BB middle
#     <= 0.01; BB upper/lower vs talib BBANDS with std x sqrt(20/19) <= 0.02;
#     bash ATR vs talib.SMA(TRANGE, 14) <= 0.01 (Wilder talib.ATR difference
#     only reported); OBV exact; calc_stochastic (H L C) vs STOCHF fastk and
#     calc_williams_r vs WILLR <= 0.01.
# (b) agents/technical/bash_compat.py vs bash, exact as strings at bash's
#     printed precision: the same indicators (+ the closes-only stochastic /
#     Williams %R the scan really computes, + detect_market_regime), and the
#     score_* functions on 40 edge inputs (30/70, 20/80, 0.3/0.7 boundaries,
#     empty and negative arguments).
# (c) bash_compat.v2_from_bars vs tests/fixtures/agents/parity/v2_windows.json
#     (real bash, 65 entries): regime, mr/tf/obv scores, kalman_trend and the
#     regime/technical/volume component scores exact on every window;
#     confluence_score exact on >= 95% and |diff| <= 1 on all;
#     recommendation equal on >= 95%.
# (d) 3 live bash recomputes (one per symbol, ML absent) through
#     gen_bash_v2_goldens.sh equal the stored goldens.
# Needs AGENTS_PY (the runner exports it; default .venv-agents/bin/python).
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
AGENTS_PY="${AGENTS_PY:-$PROJECT_DIR/.venv-agents/bin/python}"
PARITY_DIR="$TEST_DIR/fixtures/agents/parity"
GEN="$PARITY_DIR/gen_bash_v2_goldens.sh"
BARS_DIR="$TEST_DIR/fixtures/agents/bars"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_agents_parity.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export SST_OFFLINE=1
export REGIME_CACHE_DIR="$WORK_DIR/regime"
mkdir -p "$REGIME_CACHE_DIR"
pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $1"
}
fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $1"
    [[ -n "$2" ]] && echo "  $2"
}
# Read "PASS|name", "FAIL|name|detail" and "INFO|text" lines from the helper
consume() {
    local kind name detail
    while IFS='|' read -r kind name detail; do
        case "$kind" in
            PASS) pass "$name" ;;
            FAIL) fail "$name" "$detail" ;;
            INFO) echo -e "${YELLOW}  info${NC}: $name${detail:+ | $detail}" ;;
            *) [[ -n "$kind" ]] && echo "$kind${name:+|$name}${detail:+|$detail}" ;;
        esac
    done
}

if [[ ! -x "$AGENTS_PY" ]]; then
    fail "agent venv python found" "$AGENTS_PY is not executable (create .venv-agents first)"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    exit 1
fi

# ============================================================================
# Bash side of (a)/(b): indicator outputs on 9 windows
# ============================================================================
# bash_indicators SYM END -> one JSON object of bash output strings
bash_indicators() {
    local sym=$1 end=$2
    /bin/bash -c '
        source "$1/lib/indicators.sh" >/dev/null 2>&1
        source "$1/lib/scoring.sh" >/dev/null 2>&1
        source "$1/lib/regime_detector.sh" >/dev/null 2>&1
        rows=$(awk -F, -v e="$3" "NR > 1 { i = NR - 2; if (i > e - 60 && i <= e) print \$3, \$4, \$5, \$6 }" "$2")
        closes=($(echo "$rows" | awk "{ print \$3 }"))
        hlc=($(echo "$rows" | awk "{ print \$1, \$2, \$3 }"))
        cv=($(echo "$rows" | awk "{ print \$3, \$4 }"))
        jq -n -c --arg rsi "$(calc_rsi 14 "${closes[@]}")" \
            --arg ema12 "$(calc_ema 12 "${closes[@]}")" --arg ema26 "$(calc_ema 26 "${closes[@]}")" \
            --arg macd "$(calc_macd "${closes[@]}")" --arg bb "$(calc_bollinger_bands 20 2 "${closes[@]}")" \
            --arg atr "$(calc_atr 14 "${hlc[@]}")" --arg obv "$(calc_obv "${cv[@]}")" \
            --arg stoch_hlc "$(calc_stochastic 14 "${hlc[@]}")" --arg will_hlc "$(calc_williams_r 14 "${hlc[@]}")" \
            --arg stoch_closes "$(calc_stochastic 14 "${closes[@]}")" --arg will_closes "$(calc_williams_r 14 "${closes[@]}")" \
            --arg regime "$(detect_market_regime "$4" "${#closes[@]}" "${closes[@]}" | jq -c "del(.timestamp)")" \
            "\$ARGS.named"' _ "$PROJECT_DIR" "$BARS_DIR/$sym.csv" "$end" "$sym"
}

echo "Bash indicator outputs (9 windows)..."
WINDOWS=(AAA:59 AAA:500 AAA:990 BBB:59 BBB:500 BBB:990 CCC:59 CCC:500 CCC:990)
for w in "${WINDOWS[@]}"; do
    ( bash_indicators "${w%%:*}" "${w##*:}" > "$WORK_DIR/ind_${w%%:*}_${w##*:}.json" ) &
done
wait

# Edge inputs for the score_* functions: "fn<TAB>arg1<TAB>arg2..."
EDGE="$WORK_DIR/edge.tsv"
{
    for a in 0 29.99 30 30.00 30.01 50 69.99 70 70.00 70.01 75.5 100 -5 ""; do printf 'score_rsi\t%s\n' "$a"; done
    for a in 19.99 20 20.01 80 80.01 105.29 -3.5 ""; do printf 'score_stochastic\t%s\n' "$a"; done
    for a in -100 -50 0 -120 5.29 ""; do printf 'score_williams_r\t%s\n' "$a"; done
    printf 'score_macd\t1.2\t1.0\t0.2\n'
    printf 'score_macd\t-1.2\t-1.0\t-0.2\n'
    printf 'score_macd\t1.0\t1.0\t-0.2\n'
    printf 'score_macd\t-1.0\t-1.2\t0.2\n'
    printf 'score_macd\t2.34\t2.34\t0.00\n'
    printf 'score_macd\t\t\t\n'
    printf 'score_bollinger_bands\t103\t110\t105\t100\n'
    printf 'score_bollinger_bands\t107\t110\t105\t100\n'
    printf 'score_bollinger_bands\t100\t110\t105\t100\n'
    printf 'score_bollinger_bands\t115\t110\t105\t100\n'
    printf 'score_bollinger_bands\t100\t\t\t\n'
    printf 'score_bollinger_bands\t104.2\t110\t105\t100\n'
} > "$EDGE"
/bin/bash -c '
    source "$1/lib/scoring.sh" >/dev/null 2>&1
    while IFS=$'"'"'\t'"'"' read -r fn a b c d; do
        case "$fn" in
            score_rsi|score_stochastic|score_williams_r) out=$("$fn" "$a" 2>/dev/null) ;;
            score_macd) out=$(score_macd "$a" "$b" "$c" 2>/dev/null) ;;
            score_bollinger_bands) out=$(score_bollinger_bands "$a" "$b" "$c" "$d" 2>/dev/null) ;;
        esac
        printf "%s\n" "$out"
    done < "$2"' _ "$PROJECT_DIR" "$EDGE" > "$WORK_DIR/edge_bash.txt"

# ============================================================================
# (a) + (b) + (c): one Python helper
# ============================================================================
echo ""
echo "(a) TA-Lib vs bash, (b) bash_compat vs bash, (c) v2 port vs stored bash windows:"
# (output goes to a file and is consumed in this shell, so the counters stay)
cd "$PROJECT_DIR" && "$AGENTS_PY" - "$WORK_DIR" "$PARITY_DIR/v2_windows.json" > "$WORK_DIR/helper.out" 2>&1 <<'PY'
import csv, json, math, os, sys
import numpy as np
import talib
sys.path.insert(0, os.getcwd())
from agents.technical import bash_compat as bc

work, goldens_path = sys.argv[1], sys.argv[2]
BARS = os.path.join("tests", "fixtures", "agents", "bars")
_rows = {}

def rows(sym):
    if sym not in _rows:
        with open(os.path.join(BARS, sym + ".csv")) as f:
            _rows[sym] = list(csv.DictReader(f))
    return _rows[sym]

def window(sym, end):
    return rows(sym)[end - 59:end + 1]

def out(kind, name, detail=""):
    print("%s|%s|%s" % (kind, name, str(detail).replace("|", "/").replace("\n", " ")))

def check(ok, name, detail=""):
    out("PASS" if ok else "FAIL", name, "" if ok else detail)

def near(a, b, tol):
    return abs(float(a) - float(b)) <= tol

for fn in sorted(os.listdir(work)):
    if not (fn.startswith("ind_") and fn.endswith(".json")):
        continue
    _, sym, end = fn[:-5].split("_")
    end = int(end)
    b = json.load(open(os.path.join(work, fn)))
    w = window(sym, end)
    tag = "%s@%d" % (sym, end)
    h = np.array([float(r["high"]) for r in w]); l = np.array([float(r["low"]) for r in w])
    c = np.array([float(r["close"]) for r in w]); v = np.array([float(r["volume"]) for r in w])
    closes = [r["close"] for r in w]
    hlc = [x for r in w for x in (r["high"], r["low"], r["close"])]
    cv = [x for r in w for x in (r["close"], r["volume"])]

    # ---- (a) TA-Lib vs bash ------------------------------------------------
    rsi_b = json.loads(b["rsi"])["rsi"]
    rsi_t = talib.RSI(c, 14)[-1]
    check(near(rsi_b, rsi_t, 0.05), "(a) %s RSI14 bash %.2f vs talib %.4f (<= 0.05)" % (tag, rsi_b, rsi_t), "diff %.4f" % abs(rsi_b - rsi_t))
    e12_b = float(json.loads(b["ema12"])[-1]); e26_b = float(json.loads(b["ema26"])[-1])
    e12_t = talib.EMA(c, 12)[-1]; e26_t = talib.EMA(c, 26)[-1]
    check(near(e12_b, e12_t, 0.05), "(a) %s EMA12 vs talib.EMA (<= 0.05)" % tag, "diff %.4f" % abs(e12_b - e12_t))
    check(near(e26_b, e26_t, 0.05), "(a) %s EMA26 vs talib.EMA (<= 0.05)" % tag, "diff %.4f" % abs(e26_b - e26_t))
    m = json.loads(b["macd"])
    check(near(m["macd"], e12_t - e26_t, 0.1), "(a) %s MACD line vs talib EMA12-EMA26 (<= 0.1)" % tag, "diff %.4f" % abs(m["macd"] - (e12_t - e26_t)))
    check(m["histogram"] == 0 and m["signal"] == m["macd"], "(a) %s bash MACD histogram == 0 (signal == macd quirk pinned)" % tag, str(m))
    _, sig_t, hist_t = talib.MACD(c, 12, 26, 9)
    out("INFO", "%s talib MACD signal %.4f hist %.4f (bash signal = macd %.2f; not asserted)" % (tag, sig_t[-1], hist_t[-1], m["macd"]))
    bb = json.loads(b["bb"])
    up_t, mid_t, lo_t = talib.BBANDS(c, 20, 2, 2, 0)
    k = math.sqrt(20.0 / 19.0)
    up_s = mid_t[-1] + (up_t[-1] - mid_t[-1]) * k; lo_s = mid_t[-1] - (mid_t[-1] - lo_t[-1]) * k
    check(near(bb["middle"], mid_t[-1], 0.01), "(a) %s BB middle vs talib (<= 0.01)" % tag, "diff %.4f" % abs(bb["middle"] - mid_t[-1]))
    check(near(bb["upper"], up_s, 0.02) and near(bb["lower"], lo_s, 0.02),
          "(a) %s BB upper/lower vs talib BBANDS std x sqrt(20/19) (<= 0.02)" % tag,
          "upper %.4f/%.4f lower %.4f/%.4f" % (bb["upper"], up_s, bb["lower"], lo_s))
    atr_b = float(b["atr"]); atr_sma = talib.SMA(talib.TRANGE(h, l, c), 14)[-1]; atr_w = talib.ATR(h, l, c, 14)[-1]
    check(near(atr_b, atr_sma, 0.01), "(a) %s ATR vs talib.SMA(TRANGE,14) (<= 0.01)" % tag, "diff %.4f" % abs(atr_b - atr_sma))
    out("INFO", "%s talib.ATR (Wilder) %.4f vs bash %.2f: diff %.4f (not asserted)" % (tag, atr_w, atr_b, abs(atr_w - atr_b)))
    obv_b = json.loads(b["obv"]); obv_t = talib.OBV(c, v)
    check(len(obv_b) == len(obv_t) and all(float(x) == float(y) for x, y in zip(obv_b, obv_t)), "(a) %s OBV exact (all 60 values)" % tag, "last %s vs %s" % (obv_b[-1], obv_t[-1]))
    k_b = json.loads(b["stoch_hlc"])["k_line"]; k_t = talib.STOCHF(h, l, c, 14, 3, 0)[0][-1]
    check(near(k_b, k_t, 0.01), "(a) %s calc_stochastic (HLC) vs STOCHF fastk (<= 0.01)" % tag, "diff %.4f" % abs(k_b - k_t))
    w_b = float(b["will_hlc"]); w_t = talib.WILLR(h, l, c, 14)[-1]
    check(near(w_b, w_t, 0.01), "(a) %s calc_williams_r vs WILLR (<= 0.01)" % tag, "diff %.4f" % abs(w_b - w_t))

    # ---- (b) bash_compat vs bash, exact strings -----------------------------
    port = {
        "rsi": bc.calc_rsi(14, closes), "ema12": bc.calc_ema(12, closes), "ema26": bc.calc_ema(26, closes),
        "macd": bc.calc_macd(closes), "bb": bc.calc_bollinger_bands(20, 2, closes),
        "atr": bc.calc_atr(14, hlc), "obv": bc.calc_obv(cv),
        "stoch_hlc": bc.calc_stochastic(14, hlc), "will_hlc": bc.calc_williams_r(14, hlc),
    }
    port["stoch_closes"], port["will_closes"] = bc.scan_stoch_williams_from_closes(closes)
    for key in ("rsi", "ema12", "ema26", "macd", "bb", "atr", "obv", "stoch_hlc", "will_hlc", "stoch_closes", "will_closes"):
        check(port[key] == b[key], "(b) %s %s exact" % (tag, key), "bash %s / port %s" % (b[key][:120], port[key][:120]))
    rg_b = json.loads(b["regime"]); rg_p = bc.detect_market_regime(closes, sym)
    check(rg_b == rg_p, "(b) %s detect_market_regime exact (%s)" % (tag, rg_b.get("regime")), "bash %s / port %s" % (rg_b, rg_p))

# ---- (b) score_* edge inputs ------------------------------------------------
edge_in = [line.rstrip("\n").split("\t") for line in open(os.path.join(work, "edge.tsv"))]
edge_bash = [line.rstrip("\n") for line in open(os.path.join(work, "edge_bash.txt"))]
check(len(edge_in) == 40 and len(edge_bash) == 40, "(b) 40 score_* edge inputs ran in bash", "%d inputs, %d outputs" % (len(edge_in), len(edge_bash)))
for args, want in zip(edge_in, edge_bash):
    fn, a = args[0], (args[1:] + ["", "", "", ""])[:4]
    f = getattr(bc, fn)
    got = f(a[0]) if fn in ("score_rsi", "score_stochastic", "score_williams_r") else (f(a[0], a[1], a[2]) if fn == "score_macd" else f(*a))
    check(got == want, "(b) %s(%s) = %s" % (fn, ",".join(repr(x) for x in args[1:]), want), "port %s" % got)

# ---- (c) v2 port vs stored bash windows -------------------------------------
gold = json.load(open(goldens_path))
check(len(gold) == 65, "(c) v2_windows.json has 65 entries", str(len(gold)))
n_exact = n_within = n_rec = 0
mism = []
for g in gold:
    w = window(g["symbol"], g["end_index"])
    cv2 = g["confluence_v2"]
    if g["ml_mode"] == "absent":
        ml = "absent"
    else:
        ml = {"available": False, "reason": cv2["components"]["ml_confidence"].get("reason")}
    p = bc.v2_from_bars(w, ml_mode=ml, symbol=g["symbol"])
    gv, pv = g["v2_inputs"], p["v2_inputs"]
    fields = {
        "regime": (gv["regime"], pv["regime"]), "mr_score": (gv["mr_score"], pv["mr_score"]),
        "tf_score": (gv["tf_score"], pv["tf_score"]), "obv_score": (gv["obv_score"], pv["obv_score"]),
        "kalman_trend": (gv["kalman_trend"], pv["kalman_trend"]),
    }
    for comp in ("regime_score", "technical_score", "volume_trend_score"):
        fields[comp] = (cv2["components"][comp]["score"], p["components"][comp]["score"])
        fields[comp + ".weight_percent"] = (cv2["components"][comp]["weight_percent"], p["components"][comp]["weight_percent"])
    fields["ml_confidence"] = (cv2["components"]["ml_confidence"], p["components"]["ml_confidence"])
    fields["sentiment"] = (cv2["components"].get("sentiment"), p["components"].get("sentiment"))
    fields["scores"] = ({k: g["scores"][k] for k in ("rsi", "macd", "bollinger_bands", "stochastic", "williams_r", "obv")},
                        {k: p["scores"][k] for k in ("rsi", "macd", "bollinger_bands", "stochastic", "williams_r", "obv")})
    fields["indicators"] = (g["indicators"], {k: (json.loads(x) if k != "williams_r" and k != "atr" else float(x)) for k, x in p["indicators"].items()})
    bad = [k for k, (x, y) in fields.items() if x != y]
    check(not bad, "(c) %s: v2 inputs, component scores, indicator scores exact" % g["id"],
          "; ".join("%s bash=%s port=%s" % (k, fields[k][0], fields[k][1]) for k in bad))
    d = abs(cv2["confluence_score"] - p["confluence_score"])
    n_exact += d == 0
    n_within += d <= 1
    n_rec += cv2["recommendation"] == p["recommendation"]
    if d or cv2["recommendation"] != p["recommendation"] or cv2 != {k: p[k] for k in cv2}:
        mism.append("%s conf %s/%s rec %s/%s" % (g["id"], cv2["confluence_score"], p["confluence_score"], cv2["recommendation"], p["recommendation"]))
n = len(gold)
check(n_exact >= 0.95 * n, "(c) confluence_score exact on %d/%d windows (>= 95%%)" % (n_exact, n), "; ".join(mism))
check(n_within == n, "(c) confluence_score within 1 on %d/%d windows (all)" % (n_within, n), "; ".join(mism))
check(n_rec >= 0.95 * n, "(c) recommendation equal on %d/%d windows (>= 95%%)" % (n_rec, n), "; ".join(mism))
check(not mism, "(c) full confluence_v2 JSON (minus latency/timestamp) identical on all %d windows" % n, "; ".join(mism))
out("INFO", "parity: confluence exact %d/%d, within 1 %d/%d, recommendation %d/%d" % (n_exact, n, n_within, n, n_rec, n))

# DataFrame input path (floats) gives the same result as the CSV text
import pandas as pd
from agents.fixtures import load_fixture_bars
df = load_fixture_bars("BBB").iloc[500 - 59:501]
p_df = bc.v2_from_bars(df, ml_mode="absent", symbol="BBB")
g = [x for x in gold if x["id"] == "BBB_500_absent"]
if g:
    check(p_df["confluence_score"] == g[0]["confluence_v2"]["confluence_score"] and p_df["v2_inputs"]["regime"] == g[0]["v2_inputs"]["regime"],
          "(c) v2_from_bars(DataFrame) equals the bash golden (BBB@500)", "")
PY
helper_rc=$?
consume < "$WORK_DIR/helper.out"
[[ $helper_rc -eq 0 ]] || fail "parity helper exited 0" "exit $helper_rc: $(tail -3 "$WORK_DIR/helper.out")"

# ============================================================================
# (d) Live bash recomputes equal the stored goldens
# ============================================================================
echo ""
echo "(d) Live bash recompute (3 windows, ML absent):"
for w in AAA:59 BBB:500 CCC:990; do
    ( bash "$GEN" window "${w%%:*}" "${w##*:}" absent > "$WORK_DIR/live_${w%%:*}.json" 2>/dev/null ) &
done
wait
for w in AAA:59 BBB:500 CCC:990; do
    sym=${w%%:*}; end=${w##*:}
    id=$(printf '%s_%03d_absent' "$sym" "$end")
    want=$(jq -S -c --arg id "$id" '.[] | select(.id == $id)' "$PARITY_DIR/v2_windows.json")
    got=$(jq -S -c . "$WORK_DIR/live_$sym.json" 2>/dev/null)
    if [[ -n "$want" && "$want" == "$got" ]]; then
        pass "(d) $id: live bash recompute == stored golden"
    else
        fail "(d) $id: live bash recompute == stored golden" "stored ${want:0:200} / live ${got:0:200}"
    fi
done

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total Tests:  $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
if [[ $TESTS_FAILED -eq 0 && $TESTS_PASSED -gt 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
fi
echo -e "\n${RED}Some tests failed.${NC}"
exit 1
