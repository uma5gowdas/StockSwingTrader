#!/usr/bin/env python3
"""Local stand-in for the Alpaca trading and market data APIs (tests only).

Listens on 127.0.0.1 only, so no request ever leaves the machine. Point the
agent at it with ALPACA_BASE_URL and ALPACA_DATA_URL.

Usage: alpaca_stub_server.py PORT_FILE REQUEST_LOG ORDER_LOG

  PORT_FILE    the chosen (free) port is written here once the server listens
  REQUEST_LOG  one line per request: "METHOD PATH"
  ORDER_LOG    one JSON line per POST /v2/orders body (the orders "sent")

Endpoints:
  GET  /v2/account                         paper account
  GET  /v2/positions                       one AAPL position
  GET  /v2/stocks/<SYM>/trades/latest      last trade 123.45
  POST /v2/orders                          accepted order (symbol REJ -> 422)
Requests without APCA-API-KEY-ID / APCA-API-SECRET-KEY headers get 401.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, REQUEST_LOG, ORDER_LOG = sys.argv[1], sys.argv[2], sys.argv[3]

ACCOUNT = {
    "id": "stub-account-id-0000",
    "account_number": "PA0000STUB01",
    "status": "ACTIVE",
    "currency": "USD",
    "cash": "1000.50",
    "portfolio_value": "2503.75",
    "equity": "2503.75",
    "buying_power": "2001.00",
    "intraday_adjustments": "0",
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
    }
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep test output clean
        pass

    def _log(self):
        with open(REQUEST_LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return bool(self.headers.get("APCA-API-KEY-ID")) and bool(
            self.headers.get("APCA-API-SECRET-KEY")
        )

    def do_GET(self):
        self._log()
        if not self._authorized():
            return self._send(401, {"message": "unauthorized"})
        path = self.path.split("?", 1)[0]
        if path == "/v2/account":
            return self._send(200, ACCOUNT)
        if path == "/v2/positions":
            return self._send(200, POSITIONS)
        m = re.match(r"^/v2/stocks/([A-Z]{1,5})/trades/latest$", path)
        if m:
            return self._send(
                200,
                {"symbol": m.group(1), "trade": {"p": 123.45, "t": "2026-10-31T15:00:00Z"}},
            )
        return self._send(404, {"message": "not found"})

    def do_POST(self):
        self._log()
        if not self._authorized():
            return self._send(401, {"message": "unauthorized"})
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        if self.path != "/v2/orders":
            return self._send(404, {"message": "not found"})
        try:
            order = json.loads(raw)
        except ValueError:
            return self._send(400, {"message": "invalid json"})
        with open(ORDER_LOG, "a") as f:
            f.write(json.dumps(order) + "\n")
        if order.get("symbol") == "REJ":
            return self._send(422, {"message": "insufficient buying power"})
        return self._send(
            200,
            {
                "id": "stub-order-0001",
                "symbol": order.get("symbol"),
                "qty": str(order.get("qty")),
                "side": order.get("side"),
                "order_type": order.get("type"),
                "status": "accepted",
                "filled_at": None,
                "filled_avg_price": None,
                "created_at": "2026-10-31T15:00:00Z",
            },
        )


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(PORT_FILE, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
