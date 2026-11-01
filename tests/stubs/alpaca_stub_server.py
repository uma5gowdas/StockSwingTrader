#!/usr/bin/env python3
"""Local stand-in for the Alpaca trading and market data APIs (tests only).

Listens on 127.0.0.1 only, so no request ever leaves the machine. Point the
agent at it with ALPACA_BASE_URL and ALPACA_DATA_URL.

Usage: alpaca_stub_server.py PORT_FILE REQUEST_LOG ORDER_LOG [STATE_FILE]

  PORT_FILE    the chosen (free) port is written here once the server listens
  REQUEST_LOG  one line per request: "METHOD PATH" (hooks: "POST /hooks/<name> <body>")
  ORDER_LOG    one JSON line per POST /v2/orders body (the orders "sent")
  STATE_FILE   optional JSON, re-read on every request, to shape scenarios:
                 "account"   merged into the default account
                 "positions" replaces the default positions
                 "clock"     replaces the default clock
                 "calendar"  replaces the default calendar (list of days)
                 "orders"    pre-existing orders (listed and looked up with the
                             orders placed during the run)

Endpoints:
  GET  /v2/account                         paper account (+ last_equity,
                                           pattern_day_trader, daytrade_count)
  GET  /v2/positions                       AAPL 10, MSFT 5, NVDA 2
  GET  /v2/stocks/<SYM>/trades/latest      last trade 123.45
  GET  /v2/orders                          status=open|closed|all (default open),
                                           symbols=A,B  after=ISO  direction=asc|desc
                                           limit=N; bracket legs always nested
  GET  /v2/orders:by_client_order_id       ?client_order_id=ID (404 if unknown)
  GET  /v2/orders/<id>                     one order (404 if unknown)
  GET  /v2/clock                           default is_open true
  GET  /v2/calendar                        ?start=&end= ; default today
                                           (America/New_York) 09:30-16:00
  POST /v2/orders                          stores the order: status accepted,
                                           filled_qty "0", bracket legs held;
                                           first id stub-order-0001, then +1.
                                           Symbol REJ or a reused
                                           client_order_id -> 422.
                                           Symbol TMO: stored, then the answer is
                                           delayed STUB_SLOW_SECONDS (env, default
                                           3) to simulate a lost response.
                                           Symbol FIL: status filled, filled_qty = qty.
  POST /hooks/<name>                       200 "ok" (webhook stand-in, e.g. Slack;
                                           no key headers needed)
Other requests without APCA-API-KEY-ID / APCA-API-SECRET-KEY headers get 401.
"""
import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT_FILE, REQUEST_LOG, ORDER_LOG = sys.argv[1], sys.argv[2], sys.argv[3]
STATE_FILE = sys.argv[4] if len(sys.argv) > 4 else ""

try:
    from zoneinfo import ZoneInfo

    NY_TZ = ZoneInfo("America/New_York")
except Exception:  # pragma: no cover - zoneinfo/tzdata missing
    NY_TZ = timezone(timedelta(hours=-5))

ACCOUNT = {
    "id": "stub-account-id-0000",
    "account_number": "PA0000STUB01",
    "status": "ACTIVE",
    "currency": "USD",
    "cash": "1000.50",
    "portfolio_value": "2503.75",
    "equity": "2503.75",
    "last_equity": "2503.75",
    "buying_power": "2001.00",
    "intraday_adjustments": "0",
    "pattern_day_trader": False,
    "daytrade_count": 0,
}


def _position(symbol, qty, entry, price):
    value = qty * price
    pl = value - qty * entry
    return {
        "symbol": symbol,
        "qty": str(qty),
        "avg_entry_price": f"{entry:.2f}",
        "current_price": f"{price:.2f}",
        "market_value": f"{value:.2f}",
        "unrealized_pl": f"{pl:.2f}",
        "unrealized_plpc": f"{pl / (qty * entry):.4f}",
    }


POSITIONS = [
    {
        "symbol": "AAPL",
        "qty": "10",
        "avg_entry_price": "150.25",
        "current_price": "123.45",
        "market_value": "1234.50",
        "unrealized_pl": "-268.00",
        "unrealized_plpc": "-0.1784",
    },
    _position("MSFT", 5, 120.00, 123.45),
    _position("NVDA", 2, 100.00, 123.45),
]

OPEN_STATUSES = {
    "new",
    "accepted",
    "pending_new",
    "partially_filled",
    "held",
    "accepted_for_bidding",
    "pending_cancel",
    "pending_replace",
    "calculated",
}

ORDERS = []  # orders placed during this run (in memory)
ORDERS_LOCK = threading.Lock()
COUNTERS = {"order": 0, "leg": 0, "coid": 0}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_ts(value):
    """ISO-8601 (Z or offset, optional fraction) -> aware datetime, or None."""
    if not value:
        return None
    text = str(value).strip().replace("Z", "+00:00")
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts


def load_state():
    if not STATE_FILE or not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def default_clock():
    now = datetime.now(NY_TZ)
    today_open = now.replace(hour=9, minute=30, second=0, microsecond=0)
    today_close = now.replace(hour=16, minute=0, second=0, microsecond=0)
    next_close = today_close if now < today_close else today_close + timedelta(days=1)
    return {
        "is_open": True,
        "timestamp": now.isoformat(),
        "next_open": (today_open + timedelta(days=1)).isoformat(),
        "next_close": next_close.isoformat(),
    }


def default_calendar():
    today = datetime.now(NY_TZ).strftime("%Y-%m-%d")
    return [
        {
            "date": today,
            "open": "09:30",
            "close": "16:00",
            "session_open": "0400",
            "session_close": "2000",
        }
    ]


def all_orders(state):
    extra = state.get("orders") or []
    with ORDERS_LOCK:
        return [o for o in extra if isinstance(o, dict)] + list(ORDERS)


def next_id(kind, prefix):
    COUNTERS[kind] += 1
    return f"{prefix}-{COUNTERS[kind]:04d}"


def build_order(req):
    """Alpaca-shaped order from a POST body. Caller holds ORDERS_LOCK."""
    symbol = req.get("symbol")
    qty = req.get("qty")
    side = req.get("side")
    otype = req.get("type")
    order_class = req.get("order_class") or ""
    created = now_iso()
    fill = symbol == "FIL"
    order = {
        "id": next_id("order", "stub-order"),
        "client_order_id": req.get("client_order_id") or next_id("coid", "stub-coid"),
        "symbol": symbol,
        "qty": str(qty),
        "filled_qty": str(qty) if fill else "0",
        "side": side,
        "type": otype,
        "order_type": otype,
        "order_class": order_class,
        "time_in_force": req.get("time_in_force"),
        "limit_price": req.get("limit_price"),
        "stop_price": req.get("stop_price"),
        "status": "filled" if fill else "accepted",
        "created_at": created,
        "submitted_at": created,
        "filled_at": created if fill else None,
        "filled_avg_price": (str(req.get("limit_price") or "123.45") if fill else None),
        "legs": None,
    }
    if order_class == "bracket":
        exit_side = "sell" if side == "buy" else "buy"
        tp = (req.get("take_profit") or {}).get("limit_price")
        sl = (req.get("stop_loss") or {}).get("stop_price")
        leg_common = {
            "symbol": symbol,
            "qty": str(qty),
            "filled_qty": "0",
            "side": exit_side,
            "order_class": "bracket",
            "time_in_force": req.get("time_in_force"),
            "status": "held",
            "created_at": created,
            "filled_at": None,
            "filled_avg_price": None,
        }
        order["legs"] = [
            dict(
                leg_common,
                id=next_id("leg", "stub-leg"),
                type="limit",
                order_type="limit",
                limit_price=tp,
                stop_price=None,
            ),
            dict(
                leg_common,
                id=next_id("leg", "stub-leg"),
                type="stop",
                order_type="stop",
                limit_price=None,
                stop_price=sl,
            ),
        ]
    return order


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output clean
        pass

    def _log(self, line=None):
        with open(REQUEST_LOG, "a") as f:
            f.write((line or f"{self.command} {self.path}") + "\n")

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client gave up (timeout tests)

    def _authorized(self):
        return bool(self.headers.get("APCA-API-KEY-ID")) and bool(
            self.headers.get("APCA-API-SECRET-KEY")
        )

    def do_GET(self):
        self._log()
        if not self._authorized():
            return self._send(401, {"message": "unauthorized"})
        state = load_state()
        parts = urlsplit(self.path)
        path = parts.path
        query = {k: v[-1] for k, v in parse_qs(parts.query).items()}

        if path == "/v2/account":
            account = dict(ACCOUNT)
            account.update(state.get("account") or {})
            return self._send(200, account)
        if path == "/v2/positions":
            positions = state.get("positions")
            return self._send(200, POSITIONS if positions is None else positions)
        m = re.match(r"^/v2/stocks/([A-Z]{1,5})/trades/latest$", path)
        if m:
            return self._send(
                200,
                {"symbol": m.group(1), "trade": {"p": 123.45, "t": "2026-10-31T15:00:00Z"}},
            )
        if path == "/v2/clock":
            return self._send(200, state.get("clock") or default_clock())
        if path == "/v2/calendar":
            days = state.get("calendar")
            if days is None:
                days = default_calendar()
            start, end = query.get("start"), query.get("end")
            days = [
                d
                for d in days
                if (not start or d.get("date", "") >= start)
                and (not end or d.get("date", "") <= end)
            ]
            return self._send(200, days)
        if path == "/v2/orders:by_client_order_id":
            cid = query.get("client_order_id", "")
            for order in all_orders(state):
                if order.get("client_order_id") == cid:
                    return self._send(200, order)
            return self._send(404, {"message": "order not found"})
        m = re.match(r"^/v2/orders/([^/]+)$", path)
        if m:
            for order in all_orders(state):
                if order.get("id") == m.group(1):
                    return self._send(200, order)
            return self._send(404, {"message": "order not found"})
        if path == "/v2/orders":
            return self._send(200, self._list_orders(state, query))
        return self._send(404, {"message": "not found"})

    def _list_orders(self, state, query):
        status = query.get("status", "open")
        symbols = [s for s in query.get("symbols", "").split(",") if s]
        after = parse_ts(query.get("after"))
        result = []
        for order in all_orders(state):
            is_open = order.get("status") in OPEN_STATUSES
            if status == "open" and not is_open:
                continue
            if status == "closed" and is_open:
                continue
            if symbols and order.get("symbol") not in symbols:
                continue
            if after is not None:
                created = parse_ts(order.get("created_at"))
                if created is None or created <= after:
                    continue
            result.append(order)
        result.sort(key=lambda o: str(o.get("created_at") or ""))
        if query.get("direction", "desc") != "asc":
            result.reverse()
        try:
            limit = int(query.get("limit", "50"))
        except ValueError:
            limit = 50
        return result[:limit]

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        m = re.match(r"^/hooks/([A-Za-z0-9_.-]+)$", self.path)
        if m:
            self._log(f"POST /hooks/{m.group(1)} {raw}")
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._log()
        if not self._authorized():
            return self._send(401, {"message": "unauthorized"})
        if self.path != "/v2/orders":
            return self._send(404, {"message": "not found"})
        try:
            req = json.loads(raw)
        except ValueError:
            return self._send(400, {"message": "invalid json"})
        with open(ORDER_LOG, "a") as f:
            f.write(json.dumps(req) + "\n")
        if req.get("symbol") == "REJ":
            return self._send(422, {"message": "insufficient buying power"})
        state = load_state()
        cid = req.get("client_order_id")
        with ORDERS_LOCK:
            known = [o.get("client_order_id") for o in (state.get("orders") or [])]
            known += [o.get("client_order_id") for o in ORDERS]
            if cid and cid in known:
                reused = True
            else:
                reused = False
                order = build_order(req)
                ORDERS.append(order)
        if reused:
            return self._send(422, {"message": "client_order_id must be unique"})
        if req.get("symbol") == "TMO":
            time.sleep(float(os.environ.get("STUB_SLOW_SECONDS", "3")))
        return self._send(200, order)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    with open(PORT_FILE, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
