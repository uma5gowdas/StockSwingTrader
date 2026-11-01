"""Qlib data handlers of the quant agent (plan Q6, Q7).

  alpha158_sst14  SSTAlpha158: Qlib's Alpha158 (158 features) + the 14
                  legacy features $sst_<name> (columns SST_<NAME>) = 172
  sst14           SST14Handler: only the 14 legacy features (the XGBoost
                  baseline arm = today's ML path retrained on real data)
Label (both): LABEL0 = Ref($open, -6) / Ref($open, -1) - 1, the open t+1 ->
open t+6 return a close-t decision can trade with next-open fills.
Processors: no infer processors (trees are invariant to affine feature
normalisation and handle NaN); learn processors DropnaLabel and
CSZScoreNorm on the label (cross-sectional, no look-ahead).

The handler classes are created on first use (make_handler), so importing
this module does not import qlib.
"""

from __future__ import annotations

from typing import Dict, List, Tuple

from agents.quant.legacy_features import SST_FEATURES

LABEL_EXPR = "Ref($open, -6) / Ref($open, -1) - 1"
LABEL_NAME = "LABEL0"
LABEL_HORIZON = 6  # sessions after the feature date the label reads (Ref($open, -6))
KINDS = ("alpha158_sst14", "sst14")
FEATURE_SETS = {"alpha158_sst14": "Alpha158 + sst14", "sst14": "sst14 (lib/ml_inference.py features)"}
LEARN_PROCESSORS = [{"class": "DropnaLabel"}, {"class": "CSZScoreNorm", "kwargs": {"fields_group": "label"}}]

SST_FIELDS = ["$sst_" + n for n in SST_FEATURES]
SST_NAMES = ["SST_" + n.upper() for n in SST_FEATURES]

_CLASSES: Dict[str, type] = {}


def sst_feature_config() -> Tuple[List[str], List[str]]:
    return list(SST_FIELDS), list(SST_NAMES)


def label_config() -> Tuple[List[str], List[str]]:
    return [LABEL_EXPR], [LABEL_NAME]


def _classes() -> Dict[str, type]:
    if _CLASSES:
        return _CLASSES
    from qlib.contrib.data.handler import Alpha158
    from qlib.data.dataset.handler import DataHandlerLP

    class SSTAlpha158(Alpha158):
        """Alpha158 + the 14 sst_* fields; open-to-open 5-day label."""

        def get_feature_config(self):
            fields, names = super().get_feature_config()
            sf, sn = sst_feature_config()
            return list(fields) + sf, list(names) + sn

        def get_label_config(self):
            return label_config()

    class SST14Handler(DataHandlerLP):
        """Only the 14 sst_* fields; same label and processors."""

        def __init__(self, instruments="sst_us", start_time=None, end_time=None, freq="day",
                     infer_processors=None, learn_processors=None, fit_start_time=None, fit_end_time=None,
                     process_type=DataHandlerLP.PTYPE_A, **kwargs):
            from qlib.contrib.data.handler import check_transform_proc

            infer = check_transform_proc(infer_processors or [], fit_start_time, fit_end_time)
            learn = check_transform_proc(learn_processors if learn_processors is not None else LEARN_PROCESSORS,
                                         fit_start_time, fit_end_time)
            data_loader = {
                "class": "QlibDataLoader",
                "kwargs": {"config": {"feature": sst_feature_config(), "label": label_config()}, "freq": freq},
            }
            super().__init__(instruments=instruments, start_time=start_time, end_time=end_time,
                             data_loader=data_loader, infer_processors=infer, learn_processors=learn,
                             process_type=process_type, **kwargs)

    _CLASSES.update({"alpha158_sst14": SSTAlpha158, "sst14": SST14Handler})
    return _CLASSES


def make_handler(kind: str, instruments, start, end):
    """Handler KIND over [START, END] for INSTRUMENTS (a market name such as
    'sst_us' or a list of symbols). Qlib must be initialised."""
    if kind not in KINDS:
        raise ValueError("unknown handler kind: %r (use %s)" % (kind, ", ".join(KINDS)))
    cls = _classes()[kind]
    start, end = str(start)[:10], str(end)[:10]
    return cls(instruments=instruments, start_time=start, end_time=end,
               infer_processors=[], learn_processors=[dict(p) for p in LEARN_PROCESSORS],
               fit_start_time=start, fit_end_time=end)


def feature_count(handler) -> int:
    return int(handler.fetch(col_set="feature").shape[1])
