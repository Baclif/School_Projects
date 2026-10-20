"""
Cliff-Quant Signal Engine
==========================
Restructures the seven-filter confluence funnel from a sequential
gate ("all filters must pass") into an aggregated weak-signal model
("each filter votes a score, votes are combined").

This is the mechanism RenTech's edge actually relies on: many weak,
semi-independent predictors, none individually reliable, combined
so the aggregate is stronger than any single one. The value only
shows up if two things hold:

  1. Each Signal returns a continuous score (not a boolean), so
     partial confluence isn't thrown away.
  2. Signals are tracked individually so you can measure which
     ones are actually contributing edge and reweight/prune later.

Nothing here assumes a particular chart library or broker API —
plug your existing VisionStrategyAgent output and MT5/backtest data
into the interfaces below.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional
import math
import statistics


# ---------------------------------------------------------------------------
# 1. Signal interface
# ---------------------------------------------------------------------------

class SignalDirection(Enum):
    LONG = 1
    SHORT = -1
    NONE = 0


@dataclass
class SignalResult:
    """Output of a single filter for one evaluation instant."""
    name: str
    score: float          # -1.0 (strong short) .. +1.0 (strong long)
    confidence: float      # 0.0 .. 1.0 — how much weight this reading deserves
    direction: SignalDirection = field(init=False)

    def __post_init__(self):
        self.score = max(-1.0, min(1.0, self.score))
        self.confidence = max(0.0, min(1.0, self.confidence))
        if self.score > 0.05:
            self.direction = SignalDirection.LONG
        elif self.score < -0.05:
            self.direction = SignalDirection.SHORT
        else:
            self.direction = SignalDirection.NONE


class Signal:
    """
    Base class for a single filter in the funnel. Each concrete signal
    wraps ONE existing piece of logic (vision classifier, trendline
    check, S/R proximity, etc.) and exposes it as a scored vote instead
    of a pass/fail gate.
    """
    name: str = "unnamed_signal"
    # Signals that read the same underlying structure (price action,
    # e.g. trendline/S-R/Fibonacci) should share a `cluster` id so the
    # aggregator can down-weight redundant votes within a cluster.
    cluster: str = "default"

    def evaluate(self, context: dict) -> SignalResult:
        raise NotImplementedError


# ---------------------------------------------------------------------------
# 2. VisionStrategyAgent -> scored signal
# ---------------------------------------------------------------------------
#
# Today: VisionStrategyAgent classifies a chart into a single label
#   BREAKOUT / RETEST / RANGING / NONE
#
# Restructured: instead of returning a label, have the underlying model
# return (or derive) a probability/logit for each class, then convert
# that to a directional score. If your CV model already ends in a
# softmax, this only requires reading the pre-argmax vector instead of
# the argmax result.

class VisionSignal(Signal):
    name = "vision_strategy"
    cluster = "price_structure"

    def __init__(self, breakout_bias: SignalDirection = SignalDirection.LONG):
        # Whether a BREAKOUT classification implies long or short bias
        # is decided by the caller (breakout direction detection stays
        # in your CV layer) — this just wires the label to a sign.
        self.breakout_bias = breakout_bias

    def evaluate(self, context: dict) -> SignalResult:
        """
        Expects context["vision_probs"] = {
            "BREAKOUT": float, "RETEST": float,
            "RANGING": float, "NONE": float,
        }  (softmax output, sums to ~1.0)
        """
        probs = context.get("vision_probs")
        if not probs:
            return SignalResult(self.name, score=0.0, confidence=0.0)

        breakout_p = probs.get("BREAKOUT", 0.0)
        retest_p = probs.get("RETEST", 0.0)
        ranging_p = probs.get("RANGING", 0.0)
        none_p = probs.get("NONE", 0.0)

        # Breakout and retest both support the directional thesis;
        # ranging/none actively argue against taking a directional trade.
        directional_support = breakout_p + 0.75 * retest_p
        opposition = ranging_p + 0.5 * none_p

        raw = directional_support - opposition
        score = self.breakout_bias.value * raw
        # Confidence tracks how peaked the distribution is — a flat
        # 25/25/25/25 output should barely vote, even if the sign happens
        # to lean one way.
        confidence = max(probs.values()) if probs else 0.0

        return SignalResult(self.name, score=score, confidence=confidence)


# ---------------------------------------------------------------------------
# 3. The remaining six filters, as scored signals
# ---------------------------------------------------------------------------
# These are intentionally thin — swap the `evaluate` body for your
# existing detection logic. The point is the OUTPUT shape, not the
# detection method itself.

class MultiTimeframeBiasSignal(Signal):
    name = "mtf_bias"
    cluster = "trend_context"

    def evaluate(self, context: dict) -> SignalResult:
        # context["htf_trend_strength"]: -1..1, e.g. from ADX + slope
        strength = context.get("htf_trend_strength", 0.0)
        confidence = min(1.0, abs(strength) * 1.5)
        return SignalResult(self.name, score=strength, confidence=confidence)


class TrendlineChannelSignal(Signal):
    name = "trendline_channel"
    cluster = "price_structure"

    def evaluate(self, context: dict) -> SignalResult:
        # context["channel_position"]: -1 (at lower bound) .. +1 (at upper bound)
        # context["channel_slope_dir"]: SignalDirection of the channel itself
        pos = context.get("channel_position", 0.0)
        slope_dir = context.get("channel_slope_dir", SignalDirection.NONE)
        score = slope_dir.value * (1 - abs(pos)) if slope_dir != SignalDirection.NONE else 0.0
        confidence = 1 - abs(pos) if slope_dir != SignalDirection.NONE else 0.0
        return SignalResult(self.name, score=score, confidence=confidence)


class CandlestickConfirmationSignal(Signal):
    name = "candlestick_confirmation"
    cluster = "price_structure"

    def evaluate(self, context: dict) -> SignalResult:
        # context["candle_pattern_strength"]: -1..1 (engulfing/pin-bar strength, signed)
        strength = context.get("candle_pattern_strength", 0.0)
        confidence = min(1.0, abs(strength) * 1.2)
        return SignalResult(self.name, score=strength, confidence=confidence)


class SRFibonacciSignal(Signal):
    name = "sr_fibonacci"
    cluster = "price_structure"

    def evaluate(self, context: dict) -> SignalResult:
        # context["level_proximity"]: 0..1 (how close price is to a key level)
        # context["level_bias"]: SignalDirection implied by reaction at that level
        proximity = context.get("level_proximity", 0.0)
        bias = context.get("level_bias", SignalDirection.NONE)
        score = bias.value * proximity
        return SignalResult(self.name, score=score, confidence=proximity)


class NewsFundamentalsSignal(Signal):
    name = "news_fundamentals"
    cluster = "macro"

    def evaluate(self, context: dict) -> SignalResult:
        # context["news_risk"]: 0..1, high = imminent high-impact event
        # This filter mostly VETOES rather than directs — represent that
        # as a confidence multiplier available to the aggregator, and a
        # near-zero directional score.
        risk = context.get("news_risk", 0.0)
        return SignalResult(self.name, score=0.0, confidence=risk)


class RewardRiskSignal(Signal):
    name = "reward_risk"
    cluster = "risk_sizing"

    def evaluate(self, context: dict) -> SignalResult:
        # context["planned_rr"]: reward:risk ratio of the setup as planned
        rr = context.get("planned_rr", 0.0)
        direction = context.get("trade_direction", SignalDirection.NONE)
        # Below 1:2, this signal should actively drag the aggregate down.
        score = direction.value * min(1.0, (rr - 2.0) / 3.0)
        confidence = 1.0
        return SignalResult(self.name, score=score, confidence=confidence)


# ---------------------------------------------------------------------------
# 4. Aggregator
# ---------------------------------------------------------------------------

class SignalAggregator:
    """
    Combines SignalResults into one trade decision. Weights start
    uniform (minus a cluster-redundancy discount) and are meant to be
    replaced by learned weights once you have enough logged outcomes
    (see PerSignalTracker below) — e.g. fit a logistic regression from
    signal scores -> P(trade wins), then use the fitted coefficients
    as weights here.
    """

    def __init__(
        self,
        signals: list[Signal],
        weights: Optional[dict[str, float]] = None,
        news_veto_threshold: float = 0.8,
        min_aggregate_confidence: float = 0.35,
    ):
        self.signals = signals
        self.weights = weights or {s.name: 1.0 for s in signals}
        self.news_veto_threshold = news_veto_threshold
        self.min_aggregate_confidence = min_aggregate_confidence

    def _cluster_discount(self, results: list[SignalResult]) -> dict[str, float]:
        """Down-weight signals that share a cluster, so three correlated
        price-structure filters don't count as three independent votes."""
        cluster_counts: dict[str, int] = {}
        by_name = {r.name: r for r in results}
        for s in self.signals:
            if by_name[s.name].confidence > 0:
                cluster_counts[s.cluster] = cluster_counts.get(s.cluster, 0) + 1

        discounts = {}
        for s in self.signals:
            n = cluster_counts.get(s.cluster, 1)
            discounts[s.name] = 1.0 / math.sqrt(n) if n > 1 else 1.0
        return discounts

    def decide(self, context: dict) -> dict:
        results = [s.evaluate(context) for s in self.signals]
        by_name = {r.name: r for r in results}

        news = by_name.get("news_fundamentals")
        if news and news.confidence >= self.news_veto_threshold:
            return {
                "action": "NO_TRADE",
                "reason": "news_veto",
                "aggregate_score": 0.0,
                "aggregate_confidence": news.confidence,
                "components": results,
            }

        discounts = self._cluster_discount(results)

        weighted_sum = 0.0
        weight_total = 0.0
        for r in results:
            w = self.weights.get(r.name, 1.0) * discounts[r.name] * r.confidence
            weighted_sum += w * r.score
            weight_total += w

        aggregate_score = weighted_sum / weight_total if weight_total > 0 else 0.0
        aggregate_confidence = weight_total / sum(
            self.weights.get(s.name, 1.0) for s in self.signals
        )

        if aggregate_confidence < self.min_aggregate_confidence:
            action = "NO_TRADE"
        elif aggregate_score > 0.15:
            action = "LONG"
        elif aggregate_score < -0.15:
            action = "SHORT"
        else:
            action = "NO_TRADE"

        return {
            "action": action,
            "reason": "aggregate",
            "aggregate_score": aggregate_score,
            "aggregate_confidence": aggregate_confidence,
            "components": results,
        }


# ---------------------------------------------------------------------------
# 5. Per-signal outcome tracking (feeds weight re-fitting later)
# ---------------------------------------------------------------------------

@dataclass
class TradeOutcomeRecord:
    signal_scores: dict[str, float]
    signal_confidences: dict[str, float]
    trade_return_r: float  # realized return in R-multiples


class PerSignalTracker:
    """
    Logs (signal scores, outcome) pairs so you can later compute each
    signal's standalone Sharpe/edge and refit aggregator weights —
    this is the "know the edge of each signal in isolation" step
    RenTech's model depends on.
    """

    def __init__(self):
        self.records: list[TradeOutcomeRecord] = []

    def log(self, decision: dict, trade_return_r: float):
        scores = {r.name: r.score for r in decision["components"]}
        confidences = {r.name: r.confidence for r in decision["components"]}
        self.records.append(TradeOutcomeRecord(scores, confidences, trade_return_r))

    def signal_sharpe(self, signal_name: str, agree_threshold: float = 0.15) -> Optional[float]:
        """
        Sharpe of trades where this signal 'agreed' with the trade
        direction taken (i.e. its score pointed the same way the
        aggregate did), vs sitting out when it didn't.
        Returns None if there isn't enough data yet.
        """
        returns = []
        for rec in self.records:
            score = rec.signal_scores.get(signal_name, 0.0)
            if abs(score) < agree_threshold:
                continue
            same_direction = (score > 0 and rec.trade_return_r > 0) or (
                score < 0 and rec.trade_return_r < 0
            )
            returns.append(rec.trade_return_r if same_direction else -abs(rec.trade_return_r))

        if len(returns) < 20:
            return None
        mean = statistics.mean(returns)
        stdev = statistics.pstdev(returns) or 1e-9
        return mean / stdev

    def report(self) -> dict[str, Optional[float]]:
        names = {name for rec in self.records for name in rec.signal_scores}
        return {name: self.signal_sharpe(name) for name in sorted(names)}


# ---------------------------------------------------------------------------
# Example wiring
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    signals = [
        VisionSignal(breakout_bias=SignalDirection.LONG),
        MultiTimeframeBiasSignal(),
        TrendlineChannelSignal(),
        CandlestickConfirmationSignal(),
        SRFibonacciSignal(),
        NewsFundamentalsSignal(),
        RewardRiskSignal(),
    ]
    aggregator = SignalAggregator(signals)

    example_context = {
        "vision_probs": {"BREAKOUT": 0.55, "RETEST": 0.2, "RANGING": 0.15, "NONE": 0.10},
        "htf_trend_strength": 0.4,
        "channel_position": 0.8,
        "channel_slope_dir": SignalDirection.LONG,
        "candle_pattern_strength": 0.3,
        "level_proximity": 0.6,
        "level_bias": SignalDirection.LONG,
        "news_risk": 0.1,
        "planned_rr": 2.5,
        "trade_direction": SignalDirection.LONG,
    }

    decision = aggregator.decide(example_context)
    print(f"Action: {decision['action']}")
    print(f"Aggregate score: {decision['aggregate_score']:.3f}")
    print(f"Aggregate confidence: {decision['aggregate_confidence']:.3f}")
    for r in decision["components"]:
        print(f"  {r.name:22s} score={r.score:+.2f} conf={r.confidence:.2f}")
