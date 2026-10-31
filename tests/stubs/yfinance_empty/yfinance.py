"""Test stub: yfinance that returns no data (simulates an unknown symbol or
an empty response). Put this directory first on PYTHONPATH."""
import pandas as pd

__version__ = "stub-empty"


def download(*args, **kwargs):
    return pd.DataFrame()
