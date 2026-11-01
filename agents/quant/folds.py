"""Training folds of the quant agent (plan Q8). Pure pandas, no qlib.

The label of session i uses the opens of sessions i+1 .. i+6, so a segment
that ends at session index e must end at least EMBARGO (7) sessions before
the next segment starts: e = next_start - embargo - 1 (e + embargo < next
start). Features need WARMUP (60) sessions, so every train segment starts
at calendar[warmup].

  yearly_folds      expanding train, valid = the previous calendar year,
                    test = calendar year Y (first_test_year .. last year, the
                    last one partial); a year without sessions is skipped
  live_segment      the production model: valid = the last VALID_SESSIONS
                    sessions, train = everything before (minus the embargo)
  bar_folds_offline fixtures: N_FOLDS test blocks of TEST bars anchored at
                    the end, VALID bars before each, same embargo
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import pandas as pd

Span = Tuple[pd.Timestamp, pd.Timestamp]


@dataclass(frozen=True)
class Segment:
    name: str
    train: Span
    valid: Span
    test: Span

    def segments(self) -> Dict[str, Tuple[str, str]]:
        """{'train': (start, end), ...} as YYYY-MM-DD strings (DatasetH)."""
        return {k: (_d(v[0]), _d(v[1])) for k, v in (("train", self.train), ("valid", self.valid),
                                                      ("test", self.test))}

    def to_dict(self) -> Dict[str, object]:
        out: Dict[str, object] = {"name": self.name}
        out.update({k: list(v) for k, v in self.segments().items()})
        return out


def _d(ts) -> str:
    return pd.Timestamp(ts).strftime("%Y-%m-%d")


def _cal(calendar: Sequence) -> pd.DatetimeIndex:
    cal = pd.DatetimeIndex(pd.to_datetime(list(calendar))).normalize()
    if not cal.is_monotonic_increasing or cal.has_duplicates:
        cal = pd.DatetimeIndex(sorted(set(cal)))
    return cal


def _segment(cal: pd.DatetimeIndex, name: str, warmup: int, embargo: int,
             valid_start: int, test_start: int, test_end: int) -> Optional[Segment]:
    valid_end = test_start - embargo - 1
    train_end = valid_start - embargo - 1
    if train_end < warmup or valid_end < valid_start or test_end < test_start:
        return None
    return Segment(name, (cal[warmup], cal[train_end]), (cal[valid_start], cal[valid_end]),
                   (cal[test_start], cal[test_end]))


def yearly_folds(calendar: Sequence, first_test_year: int = 2018, embargo: int = 7,
                 warmup: int = 60) -> List[Segment]:
    """One fold per test year from FIRST_TEST_YEAR to the calendar's last year."""
    cal = _cal(calendar)
    if len(cal) <= warmup:
        return []
    years = cal.year
    out: List[Segment] = []
    for y in range(int(first_test_year), int(years.max()) + 1):
        test_idx = (years == y).nonzero()[0]
        if not len(test_idx):
            continue
        valid_idx = (years == y - 1).nonzero()[0]
        valid_start = int(valid_idx[0]) if len(valid_idx) else max(int(test_idx[0]) - 252, 0)
        seg = _segment(cal, str(y), warmup, embargo, valid_start, int(test_idx[0]), int(test_idx[-1]))
        if seg is not None:
            out.append(seg)
    return out


def live_segment(calendar: Sequence, valid_sessions: int = 252, embargo: int = 7,
                 warmup: int = 60) -> Segment:
    """Production model: valid = last VALID_SESSIONS sessions; test = the last
    session (unused by fit)."""
    cal = _cal(calendar)
    n = len(cal)
    valid_start = n - int(valid_sessions)
    train_end = valid_start - embargo - 1
    if valid_start <= 0 or train_end < warmup:
        raise ValueError("calendar too short for the live segment: %d sessions" % n)
    return Segment("live", (cal[warmup], cal[train_end]), (cal[valid_start], cal[n - 1]),
                   (cal[n - 1], cal[n - 1]))


def bar_folds_offline(calendar: Sequence, n_folds: int = 2, test: int = 126, valid: int = 126,
                      embargo: int = 7, warmup: int = 60) -> List[Segment]:
    """N_FOLDS bar-count folds anchored at the end of the calendar."""
    cal = _cal(calendar)
    n = len(cal)
    out: List[Segment] = []
    for k in range(int(n_folds)):
        test_end = n - 1 - (int(n_folds) - 1 - k) * int(test)
        test_start = test_end - int(test) + 1
        valid_end = test_start - embargo - 1
        valid_start = valid_end - int(valid) + 1
        if test_start < 0 or valid_start < 0:
            continue
        seg = _segment(cal, "bar%d" % (k + 1), warmup, embargo, valid_start, test_start, test_end)
        if seg is not None:
            out.append(seg)
    return out
