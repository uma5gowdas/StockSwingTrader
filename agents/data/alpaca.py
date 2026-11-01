"""Alpaca daily bars client: GET-only, host-whitelisted, paper asserted.

  GET {ALPACA_DATA_URL}/v2/stocks/bars?symbols=A,B&timeframe=1Day&start&end
      &adjustment=${AGENT_BARS_ADJUSTMENT:-all}&feed=${AGENT_BARS_FEED:-sip}
      &limit=10000[&page_token]
  - allowed hosts: data.alpaca.markets (https), or a loopback URL given in
    ALPACA_DATA_URL (tests); anything else raises SafetyError
  - constructing the client calls config.assert_paper() first
  - end clamped to now - 20 min (free SIP history rule: > 15 min old)
  - 403 with feed sip: one retry with feed iex, labeled "alpaca:iex"
  - 429 / 5xx: up to 3 retries honouring Retry-After
  - stale rejection: newest bar >= expected_last_session(as_of) minus
    AGENT_MAX_BAR_STALENESS_DAYS (3) business days
  - disk cache <cache_root>/data/alpaca/<SYM>_1Day_<adj>.csv + .meta.json,
    reused when it covers the range and is < 12 h old
  - include_vwap=True (quant raw store): frames get a `vwap` column (Alpaca
    `vw`, typical price (h+l+c)/3 when absent) and the cache file name gets
    `_vw`; the default (False) is the Phase 1 behaviour, unchanged
No method other than GET exists here: there is no order, cancel or account call.
"""

from __future__ import annotations

import os
import time
from datetime import date, datetime, timedelta, timezone
from typing import Callable, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

import pandas as pd
import requests

from agents.cache import atomic_write_json, cache_root, check_symbol, read_json
from agents.config import Config, SafetyError, assert_paper, load_config

NY = ZoneInfo("America/New_York")
DATA_HOST = "data.alpaca.markets"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost")
BATCH_SIZE = 50
MAX_RETRIES = 3
MAX_RETRY_AFTER_SECONDS = 30
SIP_DELAY = timedelta(minutes=20)
CACHE_MAX_AGE_SECONDS = 12 * 3600
COLUMNS = ["open", "high", "low", "close", "volume"]


def _parse_date(value) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    return datetime.strptime(str(value)[:10], "%Y-%m-%d").date()


def ny_today() -> date:
    return datetime.now(NY).date()


def expected_last_session(as_of) -> date:
    """as_of itself when it is before today, else the last weekday strictly
    before as_of (today's session is not complete yet)."""
    d = _parse_date(as_of)
    if d < ny_today():
        return d
    d -= timedelta(days=1)
    while d.weekday() >= 5:
        d -= timedelta(days=1)
    return d


def staleness_cutoff(as_of, max_days: Optional[int] = None) -> date:
    """Oldest acceptable newest-bar date for AS_OF."""
    if max_days is None:
        try:
            max_days = int(os.environ.get("AGENT_MAX_BAR_STALENESS_DAYS", "3"))
        except ValueError:
            max_days = 3
    return (pd.Timestamp(expected_last_session(as_of)) - pd.offsets.BDay(max(max_days, 0))).date()


def check_data_url(url: str) -> str:
    """Return URL (no trailing /) if its host is allowed; else SafetyError."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host == DATA_HOST and parsed.scheme == "https":
        return url.rstrip("/")
    if host in LOOPBACK_HOSTS and parsed.scheme in ("http", "https"):
        return url.rstrip("/")
    raise SafetyError("Alpaca data host not allowed: %s" % (host or "<empty>"))


class FetchError(Exception):
    """A request failed; .reason is the Unavailable reason."""

    def __init__(self, reason: str, status: Optional[int] = None):
        super().__init__(reason)
        self.reason = reason
        self.status = status


class AlpacaBarsClient:
    """Read-only daily bars from Alpaca market data."""

    def __init__(self, cfg: Optional[Config] = None, timeout: float = 20.0,
                 sleep: Callable[[float], None] = time.sleep, use_cache: bool = True,
                 include_vwap: bool = False):
        cfg = cfg if cfg is not None else load_config()
        assert_paper(cfg)  # paper-only, before anything else
        self.base = check_data_url(cfg.get("ALPACA_DATA_URL") or "https://" + DATA_HOST)
        self._key = cfg.get("ALPACA_API_KEY") or ""
        self._secret = cfg.get("ALPACA_SECRET_KEY") or ""
        self.feed = (cfg.get("AGENT_BARS_FEED") or "sip").lower()
        self.adjustment = (cfg.get("AGENT_BARS_ADJUSTMENT") or "all").lower()
        self.timeout = timeout
        self.sleep = sleep
        self.use_cache = use_cache
        self.include_vwap = bool(include_vwap)
        self.requests_made = 0
        self._session = requests.Session()

    def __repr__(self):
        return "AlpacaBarsClient(base=%r, feed=%r, key=%s)" % (self.base, self.feed, "<set>" if self._key else "<none>")

    @property
    def has_credentials(self) -> bool:
        return bool(self._key and self._secret)

    # -- HTTP (GET only) -------------------------------------------------
    def _get(self, path: str, params: Dict[str, str]) -> dict:
        url = check_data_url(self.base + path)  # re-check: never leave the whitelist
        headers = {"APCA-API-KEY-ID": self._key, "APCA-API-SECRET-KEY": self._secret,
                   "Accept": "application/json"}
        attempt = 0
        while True:
            self.requests_made += 1
            try:
                resp = self._session.request("GET", url, params=params, headers=headers, timeout=self.timeout)
            except requests.Timeout:
                raise FetchError("timeout")
            except requests.RequestException as exc:
                raise FetchError("request_failed: %s" % type(exc).__name__)
            if resp.status_code == 200:
                try:
                    return resp.json()
                except ValueError:
                    raise FetchError("invalid_json")
            if (resp.status_code == 429 or resp.status_code >= 500) and attempt < MAX_RETRIES:
                attempt += 1
                try:
                    wait = float(resp.headers.get("Retry-After", ""))
                except ValueError:
                    wait = float(2 ** (attempt - 1))
                self.sleep(min(max(wait, 0.0), MAX_RETRY_AFTER_SECONDS))
                continue
            raise FetchError("http_%d" % resp.status_code, resp.status_code)

    # -- bars ------------------------------------------------------------
    @staticmethod
    def _end_param(end) -> datetime:
        end_d = _parse_date(end)
        end_dt = datetime(end_d.year, end_d.month, end_d.day, 23, 59, 59, tzinfo=NY).astimezone(timezone.utc)
        return min(end_dt, datetime.now(timezone.utc) - SIP_DELAY)

    def _fetch_batch(self, symbols: List[str], start, end_dt: datetime, feed: str) -> Dict[str, list]:
        params = {
            "symbols": ",".join(symbols), "timeframe": "1Day",
            "start": _parse_date(start).isoformat(),
            "end": end_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "adjustment": self.adjustment, "feed": feed, "limit": "10000",
        }
        merged: Dict[str, list] = {}
        while True:
            payload = self._get("/v2/stocks/bars", params)
            for sym, rows in (payload.get("bars") or {}).items():
                merged.setdefault(sym, []).extend(rows or [])
            token = payload.get("next_page_token")
            if not token:
                return merged
            params = dict(params, page_token=token)

    @staticmethod
    def rows_to_frame(rows: Iterable[dict], include_vwap: bool = False) -> pd.DataFrame:
        """Alpaca bar records -> DataFrame indexed by America/New_York date.
        INCLUDE_VWAP adds `vwap` (Alpaca `vw`, else (h+l+c)/3)."""
        cols = COLUMNS + ["vwap"] if include_vwap else COLUMNS
        recs = []
        for r in rows:
            ts = pd.Timestamp(r["t"])
            ts = ts.tz_localize("UTC") if ts.tzinfo is None else ts
            rec = {"date": pd.Timestamp(ts.tz_convert(NY).date()),
                   "open": float(r["o"]), "high": float(r["h"]), "low": float(r["l"]),
                   "close": float(r["c"]), "volume": float(r["v"])}
            if include_vwap:
                vw = r.get("vw")
                rec["vwap"] = float(vw) if vw is not None else (rec["high"] + rec["low"] + rec["close"]) / 3.0
            recs.append(rec)
        if not recs:
            return pd.DataFrame(columns=cols, index=pd.DatetimeIndex([], name="date"))
        df = pd.DataFrame(recs).drop_duplicates("date", keep="last").set_index("date").sort_index()
        return df[cols]

    # -- disk cache --------------------------------------------------------
    def _cache_files(self, symbol: str) -> Tuple[str, str]:
        base = cache_root() / "data" / "alpaca" / ("%s_1Day_%s" % (symbol, self.adjustment))
        if self.include_vwap:
            base = base.with_name(base.name + "_vw")
        return str(base) + ".csv", str(base) + ".meta.json"

    def _cache_get(self, symbol: str, start, end_d: date):
        if not self.use_cache:
            return None
        csv_path, meta_path = self._cache_files(symbol)
        meta = read_json(meta_path)
        if not isinstance(meta, dict) or not os.path.isfile(csv_path):
            return None
        try:
            fresh = time.time() - float(meta.get("fetched_at_epoch", 0)) < CACHE_MAX_AGE_SECONDS
            covers = meta["start"] <= _parse_date(start).isoformat() and meta["end"] >= end_d.isoformat()
        except (KeyError, TypeError, ValueError):
            return None
        if not (fresh and covers):
            return None
        try:
            cols = COLUMNS + ["vwap"] if self.include_vwap else COLUMNS
            df = pd.read_csv(csv_path, parse_dates=["date"]).set_index("date").sort_index()[cols]
        except (OSError, ValueError, KeyError):
            return None
        return df, meta.get("data_source", "alpaca")

    def _cache_put(self, symbol: str, df: pd.DataFrame, start, end_d: date, data_source: str) -> None:
        if not self.use_cache:
            return
        csv_path, meta_path = self._cache_files(symbol)
        os.makedirs(os.path.dirname(csv_path), exist_ok=True)
        tmp = csv_path + ".tmp.%d" % os.getpid()
        try:
            df.to_csv(tmp, index_label="date", date_format="%Y-%m-%d")
            os.replace(tmp, csv_path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        atomic_write_json(meta_path, {
            "symbol": symbol, "timeframe": "1Day", "adjustment": self.adjustment,
            "start": _parse_date(start).isoformat(), "end": end_d.isoformat(),
            "data_source": data_source, "rows": int(len(df)),
            "last_bar": df.index[-1].strftime("%Y-%m-%d") if len(df) else None,
            "fetched_at_epoch": time.time(),
            "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        })

    # -- public ------------------------------------------------------------
    def fetch(self, symbols: Iterable[str], start, end, as_of=None) -> Dict[str, object]:
        """{SYM: BarsResult | Unavailable} for daily bars START..END (dates)."""
        from agents.data.bars import BarsResult, Unavailable

        syms = [check_symbol(s) for s in symbols]
        as_of = _parse_date(as_of) if as_of else ny_today()
        end_dt = self._end_param(end)
        end_d = min(_parse_date(end), end_dt.astimezone(NY).date())
        out: Dict[str, object] = {}
        frames: Dict[str, Tuple[pd.DataFrame, str]] = {}
        todo = []
        for s in syms:
            hit = self._cache_get(s, start, end_d)
            if hit is not None:
                frames[s] = hit
            else:
                todo.append(s)
        if todo and not self.has_credentials:
            for s in todo:
                out[s] = Unavailable("alpaca credentials missing (ALPACA_API_KEY/ALPACA_SECRET_KEY)")
            todo = []
        for i in range(0, len(todo), BATCH_SIZE):
            batch = todo[i:i + BATCH_SIZE]
            feed = self.feed
            try:
                try:
                    raw = self._fetch_batch(batch, start, end_dt, feed)
                except FetchError as exc:
                    if exc.status == 403 and feed == "sip":
                        feed = "iex"
                        raw = self._fetch_batch(batch, start, end_dt, feed)
                    else:
                        raise
            except FetchError as exc:
                for s in batch:
                    out[s] = Unavailable(exc.reason)
                continue
            label = "alpaca:%s" % feed
            for s in batch:
                df = self.rows_to_frame(raw.get(s, []), include_vwap=self.include_vwap)
                if len(df):
                    self._cache_put(s, df, start, end_d, label)
                frames[s] = (df, label)
        cutoff = staleness_cutoff(as_of)
        lo, hi = pd.Timestamp(_parse_date(start)), pd.Timestamp(min(end_d, as_of))
        for s, (df, label) in frames.items():
            df = df[(df.index >= lo) & (df.index <= hi)]
            if not len(df):
                out[s] = Unavailable("no_bars")
                continue
            last = df.index[-1].date()
            if last < cutoff:
                out[s] = Unavailable("stale_data: last bar %s" % last.isoformat())
                continue
            out[s] = BarsResult(df, label, False, None)
        return {s: out[s] for s in syms}
