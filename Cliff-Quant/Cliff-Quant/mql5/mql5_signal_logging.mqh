//+------------------------------------------------------------------+
//| signal_logging.mqh                                               |
//| Bridges CBR_System.mq5 to the Python PerSignalTracker.            |
//|                                                                    |
//| Writes ONE CSV row per closed trade, with each filter's score at  |
//| entry time and the realized R-multiple outcome. This is the same |
//| shape PerSignalTracker.log() expects, just persisted to disk so   |
//| live/demo trading data survives across sessions.                  |
//|                                                                    |
//| Wire this in at the same point your EA currently evaluates the    |
//| seven-filter funnel — call LogSignalOpen() when a trade is        |
//| opened, LogSignalClose() when it's closed.                        |
//+------------------------------------------------------------------+
#property strict

#define SIGNAL_LOG_FILE "cliff_quant_signal_log.csv"

// Mirrors the seven filters in signal_engine.py — keep names in sync.
struct SignalSnapshot
  {
   double vision_strategy;
   double mtf_bias;
   double trendline_channel;
   double candlestick_confirmation;
   double sr_fibonacci;
   double news_fundamentals;
   double reward_risk;
   ulong  ticket;          // trade ticket, links open row to close row
  };

//+------------------------------------------------------------------+
//| Call at trade OPEN, right after your funnel produces its scores. |
//| Pass whatever score each filter already computes internally —    |
//| this assumes you've already converted each to a -1..+1 float as  |
//| in the Python VisionSignal / TrendlineChannelSignal / etc.       |
//+------------------------------------------------------------------+
void LogSignalOpen(const SignalSnapshot &snap)
  {
   int handle = FileOpen(SIGNAL_LOG_FILE, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("LogSignalOpen: failed to open ", SIGNAL_LOG_FILE, " err=", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);

   // event,ticket,timestamp,vision,mtf,trendline,candle,sr_fib,news,rr,outcome_R
   FileWrite(handle, "OPEN", snap.ticket, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             snap.vision_strategy, snap.mtf_bias, snap.trendline_channel,
             snap.candlestick_confirmation, snap.sr_fibonacci, snap.news_fundamentals,
             snap.reward_risk, "");

   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Call at trade CLOSE. outcome_r = realized P/L expressed in       |
//| R-multiples (P/L divided by the amount risked on the trade),     |
//| so it's directly comparable to backtest output regardless of     |
//| lot size. Positive = win, negative = loss.                       |
//+------------------------------------------------------------------+
void LogSignalClose(const ulong ticket, const double outcome_r)
  {
   int handle = FileOpen(SIGNAL_LOG_FILE, FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("LogSignalClose: failed to open ", SIGNAL_LOG_FILE, " err=", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);

   FileWrite(handle, "CLOSE", ticket, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             "", "", "", "", "", "", "", outcome_r);

   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Example call site inside your EA's trade-open logic:              |
//|                                                                    |
//|   SignalSnapshot snap;                                            |
//|   snap.vision_strategy        = visionScore;                      |
//|   snap.mtf_bias               = mtfScore;                         |
//|   snap.trendline_channel      = trendlineScore;                   |
//|   snap.candlestick_confirmation = candleScore;                    |
//|   snap.sr_fibonacci           = srFibScore;                       |
//|   snap.news_fundamentals      = newsScore;                        |
//|   snap.reward_risk            = rrScore;                          |
//|   snap.ticket                 = trade.ResultOrder();              |
//|   LogSignalOpen(snap);                                            |
//|                                                                    |
//| And in OnTradeTransaction / OnTradeClose:                         |
//|   LogSignalClose(ticket, realizedR);                              |
//+------------------------------------------------------------------+
