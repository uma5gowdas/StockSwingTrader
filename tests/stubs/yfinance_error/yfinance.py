"""Test stub: yfinance whose download always fails (simulates no network).
Put this directory first on PYTHONPATH."""

__version__ = "stub-error"


def download(*args, **kwargs):
    raise ConnectionError("stub: network unreachable")
