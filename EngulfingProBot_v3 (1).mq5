//+------------------------------------------------------------------+
//|                                      EngulfingProBot_v3.mq5      |
//| Engulfing + EMA EA with strict risk sizing and account safeguards|
//+------------------------------------------------------------------+
#property copyright "MT5 Native Bot"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Risk and order settings
input double InpRiskPercent          = 0.5;       // Risk per trade (% of balance)
input int    InpStopLoss             = 20;        // Stop Loss (pips; FX pip convention)
input int    InpTakeProfit           = 40;        // Take Profit (pips; FX pip convention)
input ulong  InpMagicNumber          = 100235;    // Unique magic number

//--- Strategy
input int    InpEmaPeriod            = 200;       // Trend filter EMA period

//--- Break-even and trailing stop
input bool   InpUseBreakEven         = true;
input int    InpBreakEvenPips        = 15;
input int    InpBreakEvenLock        = 2;
input bool   InpUseTrailing          = true;
input int    InpTrailStartPips       = 20;
input int    InpTrailStepPips        = 10;

//--- Session and spread filters (broker server time)
input bool   InpUseSessionFilter     = true;
input int    InpStartHour            = 8;
input int    InpEndHour              = 20;
input bool   InpUseSpreadFilter      = true;
input double InpMaxSpreadPips        = 2.0;

//--- Small-account protection
input bool   InpUseDailyLossLimit    = true;
input double InpMaxDailyLossPercent  = 2.0;       // Stop new entries at this EA daily loss
input int    InpMaxDailyTrades       = 5;         // Maximum entries per broker day
input bool   InpUseLossStreakLimit   = true;
input int    InpMaxConsecutiveLosses = 3;         // Stop new entries after this many losing exit deals

CTrade trade;
int emaHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPercent <= 0.0 || InpStopLoss <= 0 || InpTakeProfit <= 0 ||
      InpEmaPeriod <= 0 || InpMaxDailyLossPercent <= 0.0 ||
      InpMaxDailyTrades < 1 || InpMaxConsecutiveLosses < 1 ||
      InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
     {
      Print("Invalid input settings. Check risk, stops, limits, EMA and session hours.");
      return INIT_PARAMETERS_INCORRECT;
     }

   emaHandle = iMA(_Symbol, _Period, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
     {
      Print("Failed to create EMA indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpenPositions();

   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime <= 0 || currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   if(HasOpenPosition())
      return;

   if(!IsWithinSession() || !IsSpreadAcceptable())
      return;

   if(!DailyEntryLimitsAllowTrade())
      return;

   double emaBuf[];
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(emaHandle, 0, 1, 1, emaBuf) != 1)
     {
      Print("Could not read EMA buffer. Error: ", GetLastError());
      return;
     }

   double open1  = iOpen(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double open2  = iOpen(_Symbol, _Period, 2);
   double close2 = iClose(_Symbol, _Period, 2);
   if(open1 <= 0 || close1 <= 0 || open2 <= 0 || close2 <= 0)
      return;

   bool prevBearish = (close2 < open2);
   bool currBullish = (close1 > open1);
   bool bullEngulf  = (open1 <= close2 && close1 >= open2);
   if(prevBearish && currBullish && bullEngulf && close1 > emaBuf[0])
     {
      ExecuteTrade(ORDER_TYPE_BUY);
      return;
     }

   bool prevBullish = (close2 > open2);
   bool currBearish = (close1 < open1);
   bool bearEngulf  = (open1 >= close2 && close1 <= open2);
   if(prevBullish && currBearish && bearEngulf && close1 < emaBuf[0])
      ExecuteTrade(ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Pip size uses the usual FX convention (10 points for 3/5 digits).|
//| For metals, indices and crypto, verify the instrument's pip size.|

double PipSize()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return point * ((digits == 3 || digits == 5) ? 10.0 : 1.0);
  }

//+------------------------------------------------------------------+
int VolumeDigits(double step)
  {
   for(int d = 0; d <= 8; d++)
      if(MathAbs(step - NormalizeDouble(step, d)) < 1e-10)
         return d;
   return 8;
  }

//+------------------------------------------------------------------+
//| Calculate lots from OrderCalcProfit; never force volume upward.  |
//+------------------------------------------------------------------+
double CalculateLotSize(ENUM_ORDER_TYPE orderType, double entryPrice, double slPrice)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   if(riskMoney <= 0.0)
      return 0.0;

   double oneLotResult = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, slPrice, oneLotResult))
     {
      Print("OrderCalcProfit failed. Error: ", GetLastError());
      return 0.0;
     }

   double lossPerLot = MathAbs(oneLotResult);
   if(lossPerLot <= 0.0)
      return 0.0;

   double rawLots = riskMoney / lossPerLot;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot < minLot || step <= 0.0)
      return 0.0;

   // Round DOWN to the broker's volume step so risk is not increased.
   double lots = MathFloor((rawLots + 1e-12) / step) * step;
   lots = NormalizeDouble(lots, VolumeDigits(step));

   if(lots < minLot)
     {
      PrintFormat("Trade skipped: risk budget %.2f is too small for broker minimum volume %.8f. Required raw lots: %.8f",
                  riskMoney, minLot, rawLots);
      return 0.0;
     }

   if(lots > maxLot)
      lots = MathFloor(maxLot / step) * step;

   // Final check at the rounded volume. Floating-point profit calculation
   // can vary slightly by symbol, so reject if estimated loss exceeds budget.
   double finalResult = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, lots, entryPrice, slPrice, finalResult))
      return 0.0;
   if(MathAbs(finalResult) > riskMoney + 0.01)
     {
      Print("Trade skipped: rounded volume would exceed the risk budget.");
      return 0.0;
     }

   return lots;
  }

//+------------------------------------------------------------------+
bool TradeRequestSucceeded()
  {
   uint code = trade.ResultRetcode();
   return (code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_DONE_PARTIAL ||
           code == TRADE_RETCODE_PLACED);
  }

//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
  {
   double pip = PipSize();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(pip <= 0.0 || point <= 0.0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   double slDistance = InpStopLoss * pip;
   double tpDistance = InpTakeProfit * pip;

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;
   if(slDistance < minDistance || tpDistance < minDistance)
     {
      PrintFormat("Trade skipped: requested SL/TP distance is below broker minimum stop distance (%.5f).",
                  minDistance);
      return;
     }

   double sl, tp;
   if(orderType == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(entry - slDistance, digits);
      tp = NormalizeDouble(entry + tpDistance, digits);
     }
   else
     {
      sl = NormalizeDouble(entry + slDistance, digits);
      tp = NormalizeDouble(entry - tpDistance, digits);
     }

   double lots = CalculateLotSize(orderType, entry, sl);
   if(lots <= 0.0)
     {
      Print("Trade skipped: calculated volume is invalid or below broker minimum.");
      return;
     }

   bool sent = false;
   if(orderType == ORDER_TYPE_BUY)
      sent = trade.Buy(lots, _Symbol, 0.0, sl, tp, "EngulfingPro v3 BUY");
   else
      sent = trade.Sell(lots, _Symbol, 0.0, sl, tp, "EngulfingPro v3 SELL");

   if(!sent || !TradeRequestSucceeded())
     {
      PrintFormat("Order failed. Retcode: %u - %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return;
     }

   PrintFormat("%s accepted | Lots: %.*f | Entry: %.*f | SL: %.*f | TP: %.*f",
               orderType == ORDER_TYPE_BUY ? "BUY" : "SELL",
               VolumeDigits(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)), lots,
               digits, trade.ResultPrice(), digits, sl, digits, tp);
  }

//+------------------------------------------------------------------+
//| Daily P/L for this EA and symbol, including open position P/L.   |
//+------------------------------------------------------------------+
datetime BrokerDayStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
double TodayEAPnL()
  {
   datetime from = BrokerDayStart();
   datetime to = TimeCurrent();
   if(!HistorySelect(from, to))
     {
      Print("HistorySelect failed while checking daily limits.");
      return 0.0;
     }

   double pnl = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      pnl += HistoryDealGetDouble(deal, DEAL_PROFIT);
      pnl += HistoryDealGetDouble(deal, DEAL_SWAP);
      pnl += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      pnl += HistoryDealGetDouble(deal, DEAL_FEE);
     }

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return pnl;
  }

//+------------------------------------------------------------------+
int TodayEntryCount()
  {
   if(!HistorySelect(BrokerDayStart(), TimeCurrent()))
      return 0;
   int count = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
int TodayConsecutiveLosses()
  {
   if(!HistorySelect(BrokerDayStart(), TimeCurrent()))
      return 0;

   int losses = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;

      double net = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                   HistoryDealGetDouble(deal, DEAL_SWAP) +
                   HistoryDealGetDouble(deal, DEAL_COMMISSION) +
                   HistoryDealGetDouble(deal, DEAL_FEE);
      if(net < -0.01)
         losses++;
      else if(net > 0.01)
         break;
     }
   return losses;
  }

//+------------------------------------------------------------------+
bool DailyEntryLimitsAllowTrade()
  {
   if(InpUseDailyLossLimit)
     {
      double dayLossLimit = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxDailyLossPercent / 100.0;
      double todayPnL = TodayEAPnL();
      if(todayPnL <= -dayLossLimit)
        {
         PrintFormat("Daily loss limit reached. Today's EA P/L: %.2f", todayPnL);
         return false;
        }
     }

   if(TodayEntryCount() >= InpMaxDailyTrades)
     {
      Print("Daily maximum number of entries reached.");
      return false;
     }

   if(InpUseLossStreakLimit && TodayConsecutiveLosses() >= InpMaxConsecutiveLosses)
     {
      Print("Maximum consecutive losing exit deals reached for today.");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double pip = PipSize();
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance = MathMax(stopsLevel, freezeLevel) * point;
   if(pip <= 0.0 || point <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double newSL = currentSL;
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
        {
         if(InpUseBreakEven && bid >= openPrice + InpBreakEvenPips * pip)
           {
            double target = NormalizeDouble(openPrice + InpBreakEvenLock * pip, digits);
            if((currentSL == 0.0 || target > newSL) && bid - target >= minDistance)
               newSL = target;
           }
         if(InpUseTrailing && bid >= openPrice + InpTrailStartPips * pip)
           {
            double target = NormalizeDouble(bid - InpTrailStepPips * pip, digits);
            if(target > newSL && bid - target >= minDistance)
               newSL = target;
           }
         if(newSL > currentSL && newSL > 0.0)
           {
            if(!trade.PositionModify(ticket, newSL, currentTP) || !TradeRequestSucceeded())
               Print("BUY stop modification failed: ", trade.ResultRetcodeDescription());
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         if(InpUseBreakEven && ask <= openPrice - InpBreakEvenPips * pip)
           {
            double target = NormalizeDouble(openPrice - InpBreakEvenLock * pip, digits);
            if((currentSL == 0.0 || target < newSL) && target - ask >= minDistance)
               newSL = target;
           }
         if(InpUseTrailing && ask <= openPrice - InpTrailStartPips * pip)
           {
            double target = NormalizeDouble(ask + InpTrailStepPips * pip, digits);
            if((newSL == 0.0 || target < newSL) && target - ask >= minDistance)
               newSL = target;
           }
         if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL))
           {
            if(!trade.PositionModify(ticket, newSL, currentTP) || !TradeRequestSucceeded())
               Print("SELL stop modification failed: ", trade.ResultRetcodeDescription());
           }
        }
     }
  }

//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   if(!InpUseSessionFilter)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   if(!InpUseSpreadFilter)
      return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pip = PipSize();
   if(pip <= 0.0)
      return false;
   double spreadPips = (ask - bid) / pip;
   return (spreadPips <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
