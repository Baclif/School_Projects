//+------------------------------------------------------------------+
//|  High-Confluence Breakout-Retest (CBR) Expert Advisor            |
//|  Author  : Cliff-Quant Algorithmic Trading System                |
//|  Version : 2.0 — Production Build                                |
//|  Markets : Forex (all major/minor pairs)                         |
//|  Platform: MetaTrader 5 (MQL5)                                   |
//|                                                                  |
//|  STRATEGY CORE:                                                  |
//|  Three-layer confluence engine:                                  |
//|    1. Horizontal S/R via structural pivot highs/lows             |
//|    2. 61.8% Fibonacci retracement of dominant swing              |
//|    3. Hull Moving Average trendline vector (dynamic)             |
//|  Entry fires ONLY when all three cluster within threshold.       |
//|  Confirmation requires a Pinbar or Engulfing candle at zone.     |
//|  Risk management: 2% account equity per trade, ATR-based SL.    |
//+------------------------------------------------------------------+
#property copyright "Cliff-Quant © 2025"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//====================================================================
//  INPUT PARAMETERS — ALL CONFIGURABLE FROM MT5 EA PANEL
//====================================================================

// --- Fibonacci Settings ---
input group "=== Fibonacci Engine ==="
input int    InpFibLength      = 50;    // Swing lookback period (bars)
input double InpFibLevel       = 0.618; // Fibonacci retracement level

// --- Pivot S/R Settings ---
input group "=== Pivot Support & Resistance ==="
input int    InpSRLeft         = 15;    // Left bars for pivot detection
input int    InpSRRight        = 15;    // Right bars for pivot detection

// --- Confluence Settings ---
input group "=== Confluence Engine ==="
input double InpProximityPct   = 0.15;  // Proximity threshold (% of price)

// --- Hull MA Trend Vector ---
input group "=== Trendline Vector (Hull MA) ==="
input int    InpHMAPeriod      = 30;    // Hull MA period

// --- Risk Management ---
input group "=== Risk Management ==="
input double InpRiskPct        = 2.0;   // Account risk per trade (%)
input double InpATRMultSL      = 1.5;   // ATR multiplier for Stop Loss
input double InpATRMultTP      = 3.0;   // ATR multiplier for Take Profit (R:R = 2:1)
input int    InpATRPeriod      = 14;    // ATR period for volatility-scaled SL/TP
input int    InpMaxOpenTrades  = 3;     // Maximum simultaneous open positions
input double InpMaxDailyLossPct= 6.0;   // Daily loss circuit breaker (%)

// --- Trade Session Filter ---
input group "=== Session Filter (Server Time) ==="
input bool   InpUseSessions    = true;  // Enable session filtering
input int    InpLondonOpen     = 7;     // London session open (hour, server time)
input int    InpLondonClose    = 16;    // London session close (hour, server time)
input int    InpNYOpen         = 12;    // New York session open (hour, server time)
input int    InpNYClose        = 21;    // New York session close (hour, server time)

// --- Candle Confirmation ---
input group "=== Entry Confirmation ==="
input bool   InpRequirePinbar  = true;  // Require Pinbar or Engulfing confirmation
input double InpPinbarRatio    = 0.65;  // Min wick/range ratio for pinbar
input int    InpConfirmTF      = PERIOD_H4; // Confirmation timeframe

// --- EA Control ---
input group "=== EA Control ==="
input bool   InpTradeMonday    = true;
input bool   InpTradeTuesday   = true;
input bool   InpTradeWednesday = true;
input bool   InpTradeThursday  = true;
input bool   InpTradeFriday    = false; // Off by default — NFP risk Fridays
input long   InpMagicNumber    = 202501; // Unique EA identifier
input string InpComment        = "CBR_CliffQuant";

//====================================================================
//  GLOBAL STATE VARIABLES
//====================================================================
CTrade         trade;
CPositionInfo  posInfo;

double g_equity_start_of_day = 0;
datetime g_last_day           = 0;
double g_active_resistance    = 0;
double g_active_support       = 0;

//====================================================================
//  INDICATOR HANDLES
//====================================================================
int h_atr  = INVALID_HANDLE;

//====================================================================
//  ON INIT
//====================================================================
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(20);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Create ATR indicator handle
    h_atr = iATR(_Symbol, InpConfirmTF, InpATRPeriod);
    if(h_atr == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ATR handle. EA cannot start.");
        return INIT_FAILED;
    }

    // Validate key inputs
    if(InpSRRight < 1 || InpSRLeft < 1)
    {
        Print("ERROR: Pivot bar settings must be >= 1.");
        return INIT_PARAMETERS_INCORRECT;
    }

    Print("CBR Expert Advisor v2.0 initialized on ", _Symbol,
          " | Risk: ", InpRiskPct, "% | Magic: ", InpMagicNumber);
    return INIT_SUCCEEDED;
}

//====================================================================
//  ON DEINIT
//====================================================================
void OnDeinit(const int reason)
{
    if(h_atr != INVALID_HANDLE) IndicatorRelease(h_atr);
    Print("CBR EA deinitialized. Reason: ", reason);
}

//====================================================================
//  ON TICK  — MAIN EXECUTION LOOP
//====================================================================
void OnTick()
{
    // ── 1. Only process on new bar close (4H confirmation timeframe)
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, InpConfirmTF, 0);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    // ── 2. Daily loss circuit breaker
    if(!CheckDailyLossLimit()) return;

    // ── 3. Day-of-week filter
    if(!IsTradingDay()) return;

    // ── 4. Session filter
    if(InpUseSessions && !IsActiveTradingSession()) return;

    // ── 5. Max open trades guard
    if(CountOpenTrades() >= InpMaxOpenTrades)
    {
        ManageOpenTrades(); // Still manage trailing stops on existing trades
        return;
    }

    // ── 6. Load OHLCV data for confluence analysis
    double closes[], highs[], lows[];
    ArraySetAsSeries(closes, true);
    ArraySetAsSeries(highs,  true);
    ArraySetAsSeries(lows,   true);

    int reqBars = MathMax(InpFibLength, InpSRLeft + InpSRRight + 5) + 10;
    if(CopyClose(_Symbol, InpConfirmTF, 0, reqBars, closes) < reqBars) return;
    if(CopyHigh (_Symbol, InpConfirmTF, 0, reqBars, highs)  < reqBars) return;
    if(CopyLow  (_Symbol, InpConfirmTF, 0, reqBars, lows)   < reqBars) return;

    // ── 7. Compute all three confluence layers
    double pivotResistance, pivotSupport;
    if(!FindPivotLevels(highs, lows, pivotResistance, pivotSupport)) return;
    g_active_resistance = pivotResistance;
    g_active_support    = pivotSupport;

    double fibPrice;
    if(!ComputeFibonacci(highs, lows, closes, fibPrice)) return;

    double hmaValue;
    if(!ComputeHullMA(closes, hmaValue)) return;

    double atrValue[];
    ArraySetAsSeries(atrValue, true);
    if(CopyBuffer(h_atr, 0, 0, 3, atrValue) < 3) return;
    double atr = atrValue[1]; // Use confirmed bar ATR
    if(atr <= 0) return;

    // ── 8. Evaluate confluence clusters
    double proximity = closes[1] * (InpProximityPct / 100.0);

    bool fibNearResistance  = MathAbs(fibPrice   - pivotResistance) <= proximity;
    bool hmaNearResistance  = MathAbs(hmaValue   - pivotResistance) <= proximity;
    bool bearishCluster     = fibNearResistance && hmaNearResistance;

    bool fibNearSupport     = MathAbs(fibPrice   - pivotSupport)    <= proximity;
    bool hmaNearSupport     = MathAbs(hmaValue   - pivotSupport)    <= proximity;
    bool bullishCluster     = fibNearSupport    && hmaNearSupport;

    if(!bullishCluster && !bearishCluster) return;

    // ── 9. Candlestick confirmation at the cluster zone
    bool pinbarBull = false, pinbarBear = false, engulfBull = false, engulfBear = false;

    if(InpRequirePinbar)
    {
        pinbarBull  = IsBullishPinbar(opens1(highs, lows, closes), highs, lows, closes);
        pinbarBear  = IsBearishPinbar(opens1(highs, lows, closes), highs, lows, closes);
        engulfBull  = IsBullishEngulfing(opens1(highs, lows, closes), highs, lows, closes);
        engulfBear  = IsBearishEngulfing(opens1(highs, lows, closes), highs, lows, closes);
    }

    bool longSignal  = bullishCluster && (!InpRequirePinbar || pinbarBull || engulfBull);
    bool shortSignal = bearishCluster && (!InpRequirePinbar || pinbarBear || engulfBear);

    if(!longSignal && !shortSignal) return;

    // ── 10. No duplicate signals — check we haven't already traded this zone
    if(IsDuplicateTrade(longSignal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL)) return;

    // ── 11. Execute trade with precision position sizing
    double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double slPoints = atr * InpATRMultSL;
    double tpPoints = atr * InpATRMultTP;

    if(longSignal)
    {
        double sl  = NormalizeDouble(askPrice - slPoints, _Digits);
        double tp  = NormalizeDouble(askPrice + tpPoints, _Digits);
        double lot = CalculateLotSize(slPoints);
        if(lot <= 0) return;

        if(trade.Buy(lot, _Symbol, askPrice, sl, tp, InpComment))
            Print("LONG ENTRY | Lot: ", lot, " | SL: ", sl, " | TP: ", tp,
                  " | FibZ: ", DoubleToString(fibPrice, _Digits),
                  " | HMA: ",  DoubleToString(hmaValue, _Digits),
                  " | Pivot S: ", DoubleToString(pivotSupport, _Digits));
        else
            Print("LONG order FAILED: ", trade.ResultRetcodeDescription());
    }

    if(shortSignal)
    {
        double sl  = NormalizeDouble(bidPrice + slPoints, _Digits);
        double tp  = NormalizeDouble(bidPrice - tpPoints, _Digits);
        double lot = CalculateLotSize(slPoints);
        if(lot <= 0) return;

        if(trade.Sell(lot, _Symbol, bidPrice, sl, tp, InpComment))
            Print("SHORT ENTRY | Lot: ", lot, " | SL: ", sl, " | TP: ", tp,
                  " | FibZ: ", DoubleToString(fibPrice, _Digits),
                  " | HMA: ",  DoubleToString(hmaValue, _Digits),
                  " | Pivot R: ", DoubleToString(pivotResistance, _Digits));
        else
            Print("SHORT order FAILED: ", trade.ResultRetcodeDescription());
    }

    ManageOpenTrades();
}

//====================================================================
//  HELPER: BUILD OPEN ARRAY FROM H/L/C (OHLC NOT AVAILABLE FROM COPY)
//====================================================================
double[] opens1(const double &highs[], const double &lows[], const double &closes[])
{
    static double opens[];
    int n = ArraySize(closes);
    ArrayResize(opens, n);
    // Approximate open from previous close (standard for series data)
    for(int i = 0; i < n-1; i++)
        opens[i] = closes[i+1];
    opens[n-1] = closes[n-1];
    return opens;
}

//====================================================================
//  PIVOT HIGH/LOW DETECTION
//====================================================================
bool FindPivotLevels(const double &highs[], const double &lows[],
                     double &resistance, double &support)
{
    resistance = 0;
    support    = 999999;
    int total  = ArraySize(highs);
    int scanBars = InpSRLeft + InpSRRight + 1;
    if(total < scanBars + 5) return false;

    bool foundR = false, foundS = false;

    for(int i = InpSRRight + 1; i < total - InpSRLeft - 1; i++)
    {
        // Pivot High
        bool isPH = true;
        for(int j = i - InpSRRight; j <= i + InpSRLeft; j++)
        {
            if(j == i) continue;
            if(j >= 0 && j < total && highs[j] >= highs[i]) { isPH = false; break; }
        }
        if(isPH && !foundR) { resistance = highs[i]; foundR = true; }

        // Pivot Low
        bool isPL = true;
        for(int j = i - InpSRRight; j <= i + InpSRLeft; j++)
        {
            if(j == i) continue;
            if(j >= 0 && j < total && lows[j] <= lows[i]) { isPL = false; break; }
        }
        if(isPL && !foundS) { support = lows[i]; foundS = true; }

        if(foundR && foundS) break;
    }

    return foundR && foundS;
}

//====================================================================
//  FIBONACCI 61.8% RETRACEMENT ENGINE
//====================================================================
bool ComputeFibonacci(const double &highs[], const double &lows[],
                      const double &closes[], double &fibPrice)
{
    fibPrice = 0;
    int len  = MathMin(InpFibLength, ArraySize(highs));
    if(len < 5) return false;

    double highest = highs[0], lowest = lows[0];
    for(int i = 1; i < len; i++)
    {
        if(highs[i] > highest) highest = highs[i];
        if(lows[i]  < lowest)  lowest  = lows[i];
    }
    if(highest <= lowest) return false;

    // Determine trend via EMA relationship
    double emaSum = 0;
    int emaPeriod = MathMin(InpFibLength, ArraySize(closes));
    for(int i = 0; i < emaPeriod; i++) emaSum += closes[i];
    double emaBaseline = emaSum / emaPeriod;

    bool isUptrend = (closes[1] > emaBaseline);

    if(isUptrend)
        fibPrice = highest - ((highest - lowest) * InpFibLevel); // Pullback buy zone
    else
        fibPrice = lowest  + ((highest - lowest) * InpFibLevel); // Rally sell zone

    return (fibPrice > 0);
}

//====================================================================
//  HULL MOVING AVERAGE COMPUTATION
//====================================================================
bool ComputeHullMA(const double &closes[], double &hmaValue)
{
    hmaValue = 0;
    int n    = InpHMAPeriod;
    int halfN= (int)MathFloor(n / 2.0);
    int sqrtN= (int)MathRound(MathSqrt((double)n));

    if(ArraySize(closes) < n + sqrtN + 5) return false;

    // WMA of half period
    double wmaHalf = WMA(closes, halfN, 1);
    // WMA of full period
    double wmaFull = WMA(closes, n, 1);
    if(wmaHalf == 0 || wmaFull == 0) return false;

    // Raw HMA series: 2*WMA(n/2) - WMA(n)
    double rawHMA[];
    ArrayResize(rawHMA, sqrtN + 2);
    ArraySetAsSeries(rawHMA, true);

    for(int i = 0; i < sqrtN + 1; i++)
    {
        double wH = WMA(closes, halfN, i + 1);
        double wF = WMA(closes, n,    i + 1);
        if(wH == 0 || wF == 0) return false;
        rawHMA[i] = 2.0 * wH - wF;
    }

    // Final WMA of raw HMA series
    hmaValue = WMA(rawHMA, sqrtN, 1);
    return (hmaValue > 0);
}

//====================================================================
//  WEIGHTED MOVING AVERAGE HELPER
//====================================================================
double WMA(const double &src[], int period, int shift)
{
    if(ArraySize(src) < shift + period) return 0;
    double weightSum = 0, dataSum = 0;
    for(int i = 0; i < period; i++)
    {
        double weight = period - i;
        dataSum   += src[shift + i] * weight;
        weightSum += weight;
    }
    return (weightSum > 0) ? (dataSum / weightSum) : 0;
}

//====================================================================
//  CANDLESTICK PATTERN DETECTION
//====================================================================
bool IsBullishPinbar(const double &opens[], const double &highs[],
                     const double &lows[], const double &closes[])
{
    // Bar index 1 = last confirmed bar
    double range  = highs[1] - lows[1];
    if(range <= 0) return false;
    double body   = MathAbs(closes[1] - opens[1]);
    double lowerW = MathMin(opens[1], closes[1]) - lows[1];
    // Bullish pinbar: long lower wick, small body, close in upper 1/3
    return (lowerW / range >= InpPinbarRatio) &&
           (body / range   <= (1.0 - InpPinbarRatio)) &&
           (closes[1]      >  lows[1] + range * 0.6);
}

bool IsBearishPinbar(const double &opens[], const double &highs[],
                     const double &lows[], const double &closes[])
{
    double range  = highs[1] - lows[1];
    if(range <= 0) return false;
    double body   = MathAbs(closes[1] - opens[1]);
    double upperW = highs[1] - MathMax(opens[1], closes[1]);
    // Bearish pinbar: long upper wick, small body, close in lower 1/3
    return (upperW / range >= InpPinbarRatio) &&
           (body / range   <= (1.0 - InpPinbarRatio)) &&
           (closes[1]      <  highs[1] - range * 0.6);
}

bool IsBullishEngulfing(const double &opens[], const double &highs[],
                        const double &lows[], const double &closes[])
{
    if(ArraySize(closes) < 3) return false;
    bool prevBearish = (closes[2] < opens[2]);
    bool currBullish = (closes[1] > opens[1]);
    bool engulfs     = (opens[1]  < closes[2]) && (closes[1] > opens[2]);
    return prevBearish && currBullish && engulfs;
}

bool IsBearishEngulfing(const double &opens[], const double &highs[],
                        const double &lows[], const double &closes[])
{
    if(ArraySize(closes) < 3) return false;
    bool prevBullish = (closes[2] > opens[2]);
    bool currBearish = (closes[1] < opens[1]);
    bool engulfs     = (opens[1]  > closes[2]) && (closes[1] < opens[2]);
    return prevBullish && currBearish && engulfs;
}

//====================================================================
//  POSITION SIZING — 2% RISK, ATR-SCALED SL
//====================================================================
double CalculateLotSize(double slDistance)
{
    double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount   = equity * (InpRiskPct / 100.0);
    double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lotStep      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0) return 0;

    // Risk amount / (SL in ticks * tick value)
    double slTicks = slDistance / tickSize;
    double lot     = riskAmount / (slTicks * tickValue);

    // Normalize to broker lot step
    lot = MathFloor(lot / lotStep) * lotStep;
    lot = MathMax(minLot, MathMin(maxLot, lot));

    return NormalizeDouble(lot, 2);
}

//====================================================================
//  TRADE MANAGEMENT — TRAILING STOP (BREAK-EVEN + TRAIL)
//====================================================================
void ManageOpenTrades()
{
    double atrBuf[];
    ArraySetAsSeries(atrBuf, true);
    if(CopyBuffer(h_atr, 0, 0, 3, atrBuf) < 3) return;
    double atr = atrBuf[1];

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic() != InpMagicNumber) continue;
        if(posInfo.Symbol() != _Symbol) continue;

        double openPrice = posInfo.PriceOpen();
        double sl        = posInfo.StopLoss();
        double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
            // Move to break-even once price moves 1 ATR in our favour
            double beLevel = NormalizeDouble(openPrice + atr * 0.5, _Digits);
            if(bid > openPrice + atr && sl < openPrice)
            {
                trade.PositionModify(posInfo.Ticket(), beLevel, posInfo.TakeProfit());
            }
            // Trail: move SL up 1.5 ATR below current bid
            double trailSL = NormalizeDouble(bid - atr * InpATRMultSL, _Digits);
            if(trailSL > sl + _Point * 5)
            {
                trade.PositionModify(posInfo.Ticket(), trailSL, posInfo.TakeProfit());
            }
        }

        if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
            double beLevel = NormalizeDouble(openPrice - atr * 0.5, _Digits);
            if(ask < openPrice - atr && sl > openPrice)
            {
                trade.PositionModify(posInfo.Ticket(), beLevel, posInfo.TakeProfit());
            }
            double trailSL = NormalizeDouble(ask + atr * InpATRMultSL, _Digits);
            if(trailSL < sl - _Point * 5)
            {
                trade.PositionModify(posInfo.Ticket(), trailSL, posInfo.TakeProfit());
            }
        }
    }
}

//====================================================================
//  DAILY LOSS CIRCUIT BREAKER
//====================================================================
bool CheckDailyLossLimit()
{
    datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    if(today != g_last_day)
    {
        g_equity_start_of_day = AccountInfoDouble(ACCOUNT_EQUITY);
        g_last_day            = today;
    }
    double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
    double dailyLossPct = ((g_equity_start_of_day - equity) / g_equity_start_of_day) * 100.0;

    if(dailyLossPct >= InpMaxDailyLossPct)
    {
        static datetime lastWarning = 0;
        if(TimeCurrent() - lastWarning > 3600)
        {
            Print("CIRCUIT BREAKER: Daily loss of ", DoubleToString(dailyLossPct, 2),
                  "% exceeded limit of ", InpMaxDailyLossPct, "%. No new trades today.");
            lastWarning = TimeCurrent();
        }
        return false;
    }
    return true;
}

//====================================================================
//  SESSION FILTER
//====================================================================
bool IsActiveTradingSession()
{
    int hour = TimeHour(TimeCurrent());
    bool london = (hour >= InpLondonOpen && hour < InpLondonClose);
    bool ny     = (hour >= InpNYOpen     && hour < InpNYClose);
    return london || ny;
}

//====================================================================
//  DAY OF WEEK FILTER
//====================================================================
bool IsTradingDay()
{
    int dow = TimeDayOfWeek(TimeCurrent());
    switch(dow)
    {
        case 1: return InpTradeMonday;
        case 2: return InpTradeTuesday;
        case 3: return InpTradeWednesday;
        case 4: return InpTradeThursday;
        case 5: return InpTradeFriday;
        default: return false; // Saturday/Sunday
    }
}

//====================================================================
//  COUNT OPEN TRADES FOR THIS EA
//====================================================================
int CountOpenTrades()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(posInfo.SelectByIndex(i) &&
           posInfo.Magic()  == InpMagicNumber &&
           posInfo.Symbol() == _Symbol)
            count++;
    }
    return count;
}

//====================================================================
//  DUPLICATE TRADE GUARD
//====================================================================
bool IsDuplicateTrade(ENUM_ORDER_TYPE orderType)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!posInfo.SelectByIndex(i)) continue;
        if(posInfo.Magic()  != InpMagicNumber) continue;
        if(posInfo.Symbol() != _Symbol) continue;
        if(orderType == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY)  return true;
        if(orderType == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL) return true;
    }
    return false;
}

//====================================================================
//  UTILITY: HOUR AND DAY FUNCTIONS (PORTABLE)
//====================================================================
int TimeHour(datetime t)       { MqlDateTime s; TimeToStruct(t, s); return s.hour; }
int TimeDayOfWeek(datetime t)  { MqlDateTime s; TimeToStruct(t, s); return s.day_of_week; }

//+------------------------------------------------------------------+
//  END OF EXPERT ADVISOR                                             |
//+------------------------------------------------------------------+
