"""Quant agent universe (plan Q2).

The real universe is the committed file agents/quant/universe.txt: section
`# rank` (stocks that are ranked) and `# benchmark` (ETFs ingested, never
ranked). SURVIVORSHIP BIAS: it is a fixed list of today's large caps.
Offline (fixtures) the rank universe is QAA..QLL + AAA, BBB, CCC and the
benchmark is the SPY fixture (all generated, synthetic).
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional, Union

from agents.cache import check_symbol

UNIVERSE_FILE = Path(__file__).with_name("universe.txt")
SECTIONS = ("rank", "benchmark")
SECTION_RE = re.compile(r"^#\s*(rank|benchmark)\s*$")
MIN_SIZE, MAX_SIZE = 100, 300

OFFLINE_RANK = ("QAA", "QBB", "QCC", "QDD", "QEE", "QFF", "QGG", "QHH", "QII", "QJJ", "QKK", "QLL",
                "AAA", "BBB", "CCC")
OFFLINE_BENCHMARKS = ("SPY",)


def load_universe(path: Optional[Union[str, Path]] = None, check_size: Optional[bool] = None) -> Dict[str, List[str]]:
    """{'rank': [...], 'benchmark': [...]} from the universe file.

    Comments and blank lines are ignored; a line `# rank` / `# benchmark`
    starts a section. Raises ValueError on an invalid or dotted symbol, a
    duplicate, a symbol outside a section, or (for the committed file, or
    when CHECK_SIZE) a rank size outside MIN_SIZE..MAX_SIZE.
    """
    path = Path(path) if path is not None else UNIVERSE_FILE
    if check_size is None:
        check_size = path.resolve() == UNIVERSE_FILE.resolve()
    out: Dict[str, List[str]] = {s: [] for s in SECTIONS}
    seen = set()
    section = None
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        m = SECTION_RE.match(line)
        if m:
            section = m.group(1)
            continue
        if line.startswith("#"):
            continue
        sym = line.split("#", 1)[0].strip()
        if section is None:
            raise ValueError("%s:%d: symbol %r before a '# rank' / '# benchmark' section" % (path.name, n, sym))
        check_symbol(sym)
        if "." in sym:
            raise ValueError("%s:%d: dotted ticker not allowed: %r" % (path.name, n, sym))
        if sym in seen:
            raise ValueError("%s:%d: duplicate symbol %r" % (path.name, n, sym))
        seen.add(sym)
        out[section].append(sym)
    if check_size and not (MIN_SIZE <= len(out["rank"]) <= MAX_SIZE):
        raise ValueError("rank universe has %d symbols; expected %d..%d" % (len(out["rank"]), MIN_SIZE, MAX_SIZE))
    if not out["benchmark"]:
        raise ValueError("%s: no benchmark symbols" % path.name)
    return out


def rank_universe(offline: bool) -> List[str]:
    """Symbols that are ranked."""
    return list(OFFLINE_RANK) if offline else load_universe()["rank"]


def benchmarks(offline: bool) -> List[str]:
    """Benchmark symbols (ingested, never ranked)."""
    return list(OFFLINE_BENCHMARKS) if offline else load_universe()["benchmark"]


def all_symbols(offline: bool) -> List[str]:
    """Rank symbols followed by the benchmarks."""
    return rank_universe(offline) + benchmarks(offline)
