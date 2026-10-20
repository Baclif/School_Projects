# CBR Expert Advisor — Complete Deployment & Operations Manual
**High-Confluence Breakout-Retest System | Cliff-Quant | MT5 Production Build**

---

## 1. WHAT THIS EA DOES

The CBR EA is a fully autonomous algorithmic trading system that monitors your chosen Forex pair 24/5 and fires trades only when three independent technical layers converge at the same price zone simultaneously. This multi-layer filter is designed to eliminate low-probability setups and trade only high-confidence confluences.

### The Three-Layer Confluence Engine

| Layer | What It Measures | Why It Matters |
|---|---|---|
| **Horizontal Pivot S/R** | Structural swing highs and lows from recent price history | Institutions react at these zones — they represent memory in the market |
| **61.8% Fibonacci** | Golden ratio retracement of the dominant swing leg | The most powerful natural retracement level; marks where smart money re-enters |
| **Hull MA Vector** | Dynamic trendline via weighted Hull Moving Average | Confirms directional bias and acts as institutional trendline proxy |

A trade signal is **only generated** when all three layers cluster within a configurable proximity threshold AND a confirming candlestick (Pinbar or Engulfing) prints at the zone.

---

## 2. INSTALLATION — STEP BY STEP

### Step 1: Copy the EA File
1. Open MetaTrader 5
2. Click **File → Open Data Folder**
3. Navigate to: `MQL5 → Experts`
4. Copy `CBR_System.mq5` into this folder

### Step 2: Compile
1. Open the MetaEditor (F4 from MT5, or Tools → MetaQuotes Language Editor)
2. In the Navigator panel on the left, find `CBR_System.mq5` under Experts
3. Press **F7** or click the Compile button
4. Confirm **0 errors, 0 warnings** in the Errors tab at the bottom
5. Close MetaEditor and return to MT5

### Step 3: Attach to Chart
1. Open the chart of your chosen pair (e.g. EURUSD, GBPUSD)
2. Set the chart timeframe to **H4** (this is the EA's confirmation timeframe)
3. In the Navigator panel (Ctrl+N), expand **Expert Advisors**
4. Drag `CBR_System` onto the chart

### Step 4: Configure Settings (see Section 3 below)

### Step 5: Enable AutoTrading
- Click the **AutoTrading** button in the MT5 toolbar (it turns green when active)
- Confirm the smiley face appears in the top-right of the chart (EA is running)

---

## 3. INPUT PARAMETER REFERENCE

### Fibonacci Engine
| Parameter | Default | Notes |
|---|---|---|
| Fibonacci Swing Length | 50 | Bars to look back for swing high/low. Use 50 for H4, 100 for Daily |
| Target Fib Level | 0.618 | The Golden Ratio. Do not change unless backtesting alternatives |

### Pivot Support & Resistance
| Parameter | Default | Notes |
|---|---|---|
| Pivot Left Bars | 15 | Bars to the left of pivot point. Higher = more significant levels |
| Pivot Right Bars | 15 | Bars to the right. This causes a natural lag (unavoidable for confirmed pivots) |

### Confluence Engine
| Parameter | Default | Notes |
|---|---|---|
| Proximity Threshold % | 0.15 | How tight the three layers must cluster. Lower = more selective. Try 0.10–0.25 |

### Hull MA Vector
| Parameter | Default | Notes |
|---|---|---|
| Hull MA Period | 30 | The period for the trendline vector. 30 is balanced for H4 |

### Risk Management
| Parameter | Default | Notes |
|---|---|---|
| Account Risk Per Trade % | **2.0** | 2% of current equity per trade. Lot size auto-calculates |
| ATR Multiplier for SL | 1.5 | SL = 1.5 × ATR(14) below/above entry |
| ATR Multiplier for TP | 3.0 | TP = 3.0 × ATR(14) = **2:1 Risk-Reward minimum** |
| ATR Period | 14 | Standard ATR lookback for volatility measurement |
| Max Open Trades | 3 | Hard cap on simultaneous positions for this EA on this symbol |
| Max Daily Loss % | 6.0 | Circuit breaker: halts all new trades if daily drawdown hits 6% |

### Session Filter
| Parameter | Default | Notes |
|---|---|---|
| Use Sessions | true | Restricts trading to London + New York sessions only |
| London Open/Close | 7:00 – 16:00 | Server time. Adjust if your broker uses UTC+2 or UTC+3 |
| NY Open/Close | 12:00 – 21:00 | Overlapping London/NY (12:00–16:00) is the highest-volume window |

### Entry Confirmation
| Parameter | Default | Notes |
|---|---|---|
| Require Pinbar/Engulfing | true | Highly recommended — eliminates false cluster entries |
| Pinbar Wick Ratio | 0.65 | Wick must be ≥ 65% of total candle range to qualify as pinbar |
| Confirmation Timeframe | H4 | All analysis runs on 4-hour bars |

### EA Control
| Parameter | Default | Notes |
|---|---|---|
| Trade Friday | false | Off by default due to NFP and end-of-week spread widening |
| Magic Number | 202501 | Unique ID. Change if running multiple EAs on same account |

---

## 4. TRADE LIFECYCLE — HOW A TRADE IS EXECUTED

```
TICK RECEIVED
    │
    ▼
New H4 Bar? ──No──► Exit (wait)
    │Yes
    ▼
Daily Loss < 6%? ──No──► Circuit Breaker Active
    │Yes
    ▼
Trading Day? ──No──► Exit
    │Yes
    ▼
Active Session? ──No──► Exit
    │Yes
    ▼
Open Trades < 3? ──No──► Manage Trailing Stops Only
    │Yes
    ▼
Compute Pivot S/R ──────────────────────────────┐
Compute Fibonacci 61.8%                          │ Three Layers
Compute Hull MA Vector ──────────────────────────┘
    │
    ▼
All Three Within Proximity? ──No──► Exit
    │Yes
    ▼
Bullish or Bearish Cluster?
    │
    ▼
Pinbar or Engulfing at Zone? ──No──► Exit
    │Yes
    ▼
Duplicate Trade Check ──Already Open?──► Exit
    │No
    ▼
Calculate Lot Size (2% Equity / ATR SL)
    │
    ▼
EXECUTE BUY or SELL ORDER
  SL = Entry ± (1.5 × ATR)
  TP = Entry ± (3.0 × ATR)
    │
    ▼
TRADE MANAGEMENT (every new bar)
  → Break-even trigger at +1 ATR profit
  → Trailing stop at 1.5 × ATR below/above price
```

---

## 5. RISK MANAGEMENT ARCHITECTURE

### Position Sizing Formula
```
Risk Amount    = Account Equity × 2%
SL Distance    = ATR(14) × 1.5
Lot Size       = Risk Amount ÷ (SL in ticks × Tick Value)
```

**Example on EURUSD with $10,000 account:**
- Equity: $10,000
- Risk: $200 (2%)
- ATR(14): 0.0080 (80 pips on H4)
- SL Distance: 0.0080 × 1.5 = 0.0120 (120 pips)
- Tick Value: $1 per pip per 0.01 lot
- Lot = $200 ÷ (120 × $1) = **0.16 lots**

### Drawdown Protection Layers
1. **Per-Trade SL**: ATR-based, never a fixed pip value
2. **Break-Even**: Moved to +0.5 ATR profit when price moves +1 ATR in favour
3. **Trailing Stop**: Activates after break-even, trails at 1.5 ATR
4. **Max Open Trades**: Hard cap at 3 (max simultaneous exposure = 6% equity)
5. **Daily Circuit Breaker**: Halts all entries if daily loss hits 6%
6. **No Friday Trading**: Avoids end-of-week gap risk and NFP volatility

---

## 6. RECOMMENDED PAIRS AND SETTINGS

| Pair | Fib Length | Proximity % | Notes |
|---|---|---|---|
| EURUSD | 50 | 0.12 | Most liquid, tightest spreads |
| GBPUSD | 50 | 0.15 | More volatile, wider natural swings |
| USDJPY | 50 | 0.12 | Strong trend tendencies, S/R respected |
| GBPJPY | 60 | 0.20 | High volatility — widen proximity |
| AUDUSD | 50 | 0.15 | Commodity-linked, clean Fib reactions |
| XAUUSD (Gold) | 70 | 0.25 | Very volatile, requires wider threshold |

**Run one EA instance per chart/symbol** with a unique Magic Number per instance.

---

## 7. BACKTESTING PROCEDURE

Before going live, always backtest:

1. Open **Strategy Tester** (Ctrl+R in MT5)
2. Select `CBR_System` as the Expert
3. Set Symbol: EURUSD (or your chosen pair)
4. Timeframe: **H4**
5. Date Range: Minimum 3 years (to capture trending and ranging markets)
6. Model: **Every tick based on real ticks** (highest accuracy)
7. Initial Deposit: Match your live account size
8. Run and review:
   - Profit Factor should be > 1.5
   - Max Drawdown should be < 20%
   - Win Rate is secondary — at 2:1 RR, a 40% win rate is profitable

**Optimization targets** (use MT5 Optimizer):
- `InpProximityPct`: range 0.05–0.30, step 0.05
- `InpFibLength`: range 30–100, step 10
- `InpHMAPeriod`: range 20–50, step 5

---

## 8. GOING LIVE — CHECKLIST

- [ ] EA compiled with 0 errors
- [ ] Backtest completed, Profit Factor > 1.5
- [ ] AutoTrading enabled (green button)
- [ ] Chart timeframe set to H4
- [ ] Correct Magic Number set (unique per EA instance)
- [ ] Risk confirmed at 2%
- [ ] Daily Loss Limit set (6% recommended)
- [ ] Session filter times verified against broker server time
- [ ] Tested on Demo account for minimum 2 weeks before live

---

## 9. MONITORING WHILE YOU SLEEP

The EA runs fully autonomously. To monitor remotely:
- Enable **MT5 Mobile App** — you'll receive push notifications on every trade
- Set up MT5 **Email Alerts** under Tools → Options → Email
- The EA logs all actions to the **Experts tab** (bottom of MT5) with full detail

---

*Cliff-Quant CBR System | For research and live trading use | Always risk what you can afford to lose*
