"""
load_signal_log.py
===================
Reads the CSV produced by mql5_signal_logging.mqh (FILE_COMMON, so it
lands in the MT5 "Common\\Files" folder shared across terminal
instances) and feeds it into signal_engine.PerSignalTracker.

Works for live/demo trading logs from the EA, or a backtester emitting
rows in the same shape — the format doesn't care about the source.

CSV shape (one row per event):
  event,ticket,timestamp,vision,mtf,trendline,candle,sr_fib,news,rr,outcome_R

  OPEN  rows carry the seven filter scores, outcome_R blank.
  CLOSE rows carry ticket + outcome_R, other fields blank.

Usage:
  python load_signal_log.py /path/to/cliff_quant_signal_log.csv
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

from signal_engine import PerSignalTracker, SignalResult, SignalDirection


SIGNAL_COLUMNS = [
    "vision_strategy",
    "mtf_bias",
    "trendline_channel",
    "candlestick_confirmation",
    "sr_fibonacci",
    "news_fundamentals",
    "reward_risk",
]

COL_INDEX = {
    "event": 0, "ticket": 1, "timestamp": 2,
    "vision_strategy": 3, "mtf_bias": 4, "trendline_channel": 5,
    "candlestick_confirmation": 6, "sr_fibonacci": 7,
    "news_fundamentals": 8, "reward_risk": 9, "outcome_r": 10,
}


def _fake_decision(scores: dict[str, float]) -> dict:
    """
    PerSignalTracker.log() expects the same 'decision' shape
    SignalAggregator.decide() returns. We didn't run the live
    aggregator against these historical scores, so confidence is set
    to 1.0 uniformly here — the OPEN row only stored the score, not
    the confidence, at logging time. If you want confidence-weighted
    historical Sharpe, extend the MQL5 log to also write each
    signal's confidence and thread it through here.
    """
    components = [
        SignalResult(name, score=score, confidence=1.0)
        for name, score in scores.items()
    ]
    return {"components": components}


def load(csv_path: str) -> PerSignalTracker:
    opens: dict[str, dict[str, float]] = {}
    tracker = PerSignalTracker()

    with open(csv_path, newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if not row or row[0] not in ("OPEN", "CLOSE"):
                continue

            event, ticket = row[0], row[1]

            if event == "OPEN":
                scores = {
                    col: float(row[COL_INDEX[col]])
                    for col in SIGNAL_COLUMNS
                }
                opens[ticket] = scores

            elif event == "CLOSE":
                scores = opens.pop(ticket, None)
                if scores is None:
                    print(f"warning: CLOSE for ticket {ticket} with no matching OPEN row, skipping")
                    continue
                outcome_r = float(row[COL_INDEX["outcome_r"]])
                decision = _fake_decision(scores)
                tracker.log(decision, outcome_r)

    if opens:
        print(f"warning: {len(opens)} OPEN rows never matched a CLOSE — trades still in flight?")

    return tracker


def main():
    if len(sys.argv) != 2:
        print("usage: python load_signal_log.py <path_to_csv>")
        sys.exit(1)

    csv_path = Path(sys.argv[1])
    if not csv_path.exists():
        print(f"file not found: {csv_path}")
        sys.exit(1)

    tracker = load(str(csv_path))
    report = tracker.report()

    print(f"\n{len(tracker.records)} closed trades loaded.\n")
    print(f"{'signal':28s}  sharpe")
    print("-" * 40)
    for name, sharpe in sorted(
        report.items(), key=lambda kv: (kv[1] is None, -(kv[1] or 0))
    ):
        if sharpe is None:
            print(f"{name:28s}  insufficient data (<20 agreeing trades)")
        else:
            print(f"{name:28s}  {sharpe:+.3f}")


if __name__ == "__main__":
    main()
