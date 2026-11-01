"""Universes for the validation gate (plan D19).

PHASE1_UNIVERSE is a fixed list of today's large caps (survivorship bias is
stated in every report). OFFLINE_UNIVERSE uses the generated fixtures.
"""

PHASE1_UNIVERSE = ("AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "JPM", "V", "XOM", "JNJ",
                   "PG", "HD", "KO", "PEP", "COST", "WMT", "UNH", "BAC", "CSCO", "ORCL")
PHASE1_BENCHMARK = "SPY"
OFFLINE_UNIVERSE = ("AAA", "BBB", "CCC")
OFFLINE_BENCHMARK = "SPY"  # the SPY fixture (synthetic)
REAL_START = "2016-01-01"
WARMUP_DAYS = 150  # calendar days loaded before --start so indicators / v2 windows are warm


def default_universe(offline: bool):
    return list(OFFLINE_UNIVERSE if offline else PHASE1_UNIVERSE)


def default_benchmark(offline: bool) -> str:
    return OFFLINE_BENCHMARK if offline else PHASE1_BENCHMARK
