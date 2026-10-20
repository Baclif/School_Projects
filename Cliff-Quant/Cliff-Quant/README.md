# Cliff-Quant

An independent algorithmic trading project for FX (primarily EUR/USD), built around a confluence breakout-retest strategy and moving toward a weighted multi-signal model.

## Structure

```
Cliff-Quant/
├── mql5/
│   ├── CBR_System.mq5            # MetaTrader 5 Expert Advisor (three-layer confluence engine)
│   └── mql5_signal_logging.mqh   # Logs each filter's score and the trade outcome to CSV
├── python/
│   ├── signal_engine.py          # Scored signals, weighted aggregator, per-signal Sharpe tracker
│   └── load_signal_log.py        # Reads the EA's CSV log and reports per-signal Sharpe
└── docs/
    └── CBR_Deployment_Manual.md  # Installation, parameters, backtesting and go-live checklist
```

## Components

**CBR_System.mq5.** Trades only when three layers agree within a proximity threshold: pivot support/resistance, the 61.8% Fibonacci retracement and a Hull moving average, confirmed by a pinbar or engulfing candle on H4. Position size is set from 2% equity risk and an ATR-based stop, with break-even, trailing stop, a three-position cap and a 6% daily loss circuit breaker.

**signal_engine.py.** Converts the confluence filters from pass/fail gates into scored signals (score in −1..+1, confidence in 0..1) and combines them with confidence weighting. Correlated price-structure signals are discounted so they don't count as independent votes. `PerSignalTracker` measures each signal's standalone Sharpe against realised R-multiples, to support refitting weights.

**Logging bridge.** `mql5_signal_logging.mqh` writes one CSV row at trade open (filter scores) and one at close (outcome in R). `load_signal_log.py` pairs them by ticket and prints a per-signal Sharpe report.

## Quick start

```bash
cd python
python signal_engine.py                          # example decision
python load_signal_log.py cliff_quant_signal_log.csv   # per-signal report
```

For the EA, see `docs/CBR_Deployment_Manual.md`.

## Status

Research project. Backtest and demo-trade before any live use.
