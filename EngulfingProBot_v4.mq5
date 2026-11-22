//+------------------------------------------------------------------+
//|                                      EngulfingProBot_v4.mq5      |
//| Moderate-risk EURUSD engulfing + EMA200 Expert Advisor           |
//| Prepared for a $100 USD account; demo-test before live trading.  |
//+------------------------------------------------------------------+
#property copyright "MT5 Native Bot"
#property version   "4.10"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//--- Risk and strategy
input double InpRiskPercent             = 0.5;    // Planned risk per trade (% of balance)
input int    InpStopLossPips            = 20;     // Stop loss in pips
input int    InpTakeProfitPips          = 40;     // Take profit in pips
input int    InpEMAPeriod               = 200;    // Trend EMA period
input ulong  InpMagicNumber             = 22112026;
input int    InpDeviationPoints         = 20;

//--- Trade protections
input double InpMaxSpreadPips           = 2.0;
input double InpDailyLossLimitPercent   = 2.0;    // Based on current balance
input int    InpMaxTradesPerDay         = 3;
input int    InpMaxConsecutiveLosses    = 2;
input double InpMinFreeMarginPercent    = 30.0;   // Keep at least this % of equity free
input bool   InpOnePositionAtATime      = true;

//--- Trading session, broker/server time
input int    InpSessionStartHour        = 8;
input int    InpSessionEndHour          = 20;

//--- Position management
input int    InpBreakEvenTriggerPips    = 15;
input int    InpBreakEvenLockPips       = 2;
input int    InpTrailingStartPips       = 20;
input int    InpTrailingDistancePips    = 10;

//--- Internal state
int      emaHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Pip and price helpers                                            |
//+------------------------------------------------------------------+
double PipSize()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return 10.0 * _Point;
   return _Point;
}

double CurrentSpreadPips()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || PipSize() <= 0.0)
      return 999999.0;
   return (tick.ask - tick.bid) / PipSize();
}

datetime StartOfServerDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

bool IsTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpSessionStartHour == InpSessionEndHour)
      return true; // 24-hour session

   if(InpSessionStartHour < InpSessionEndHour)
      return (dt.hour >= InpSessionStartHour &&
              dt.hour < InpSessionEndHour);

   // Session crosses midnight
   return (dt.hour >= InpSessionStartHour ||
           dt.hour < InpSessionEndHour);
}

bool IsEURUSDSymbol()
{
   string base   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   return (base == "EUR" && profit == "USD");
}

bool IsNewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);
   if(currentBar <= 0)
      return false;

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Deal and history helpers                                         |
//+------------------------------------------------------------------+
double DealNetResult(const ulong dealTicket)
{
   return HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
        + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
        + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION)
        + HistoryDealGetDouble(dealTicket, DEAL_FEE);
}

bool IsOurDeal(const ulong dealTicket)
{
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return false;
   if((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber)
      return false;
   return true;
}

bool IsExitDeal(const ulong dealTicket)
{
   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   return (entry == DEAL_ENTRY_OUT ||
           entry == DEAL_ENTRY_OUT_BY ||
           entry == DEAL_ENTRY_INOUT);
}

bool IsEntryDeal(const ulong dealTicket)
{
   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   return (entry == DEAL_ENTRY_IN);
}

bool ContainsLong(const long &values[], const long value)
{
   for(int i = 0; i < ArraySize(values); i++)
      if(values[i] == value)
         return true;
   return false;
}

double TodayStrategyProfit()
{
   datetime from = StartOfServerDay();
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to))
      return 0.0;

   double result = 0.0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || !IsOurDeal(ticket))
         continue;
      result += DealNetResult(ticket);
   }

   // Include current floating P/L and swap for this EA's open positions.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      result += PositionGetDouble(POSITION_PROFIT);
      result += PositionGetDouble(POSITION_SWAP);
   }
   return result;
}

int TodayEntryCount()
{
   datetime from = StartOfServerDay();
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to))
      return 0;

   long positionIds[];
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || !IsOurDeal(ticket) || !IsEntryDeal(ticket))
         continue;

      long positionId = (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      if(positionId > 0 && !ContainsLong(positionIds, positionId))
      {
         int n = ArraySize(positionIds);
         ArrayResize(positionIds, n + 1);
         positionIds[n] = positionId;
      }
   }
   return ArraySize(positionIds);
}

// One record per position closed today. Net result is calculated across
// every deal belonging to that position, so partial exits are not counted
// as separate losing trades.
struct ClosedPositionResult
{
   long     positionId;
   datetime closeTime;
   double   netResult;
};

int TodayClosedPositionResults(ClosedPositionResult &records[])
{
   ArrayResize(records, 0);

   datetime from = StartOfServerDay();
   datetime to   = TimeCurrent();
   if(!HistorySelect(from, to))
      return 0;

   long closedIds[];
   int todayDeals = HistoryDealsTotal();

   // Identify unique positions that had an exit deal today.
   for(int i = 0; i < todayDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || !IsOurDeal(ticket) || !IsExitDeal(ticket))
         continue;

      long positionId = (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      if(positionId <= 0 || ContainsLong(closedIds, positionId))
         continue;

      int n = ArraySize(closedIds);
      ArrayResize(closedIds, n + 1);
      closedIds[n] = positionId;

      datetime closeTime =
         (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      int r = ArraySize(records);
      ArrayResize(records, r + 1);
      records[r].positionId = positionId;
      records[r].closeTime  = closeTime;
      records[r].netResult  = 0.0;
   }

   if(ArraySize(records) == 0)
      return 0;

   // Scan available account history and aggregate all deals per position.
   if(!HistorySelect(0, to))
      return 0;

   int allDeals = HistoryDealsTotal();
   for(int i = 0; i < allDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || !IsOurDeal(ticket))
         continue;

      long positionId = (long)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      for(int r = 0; r < ArraySize(records); r++)
      {
         if(records[r].positionId == positionId)
         {
            records[r].netResult += DealNetResult(ticket);
            break;
         }
      }
   }

   // Sort newest closed position first.
   for(int a = 0; a < ArraySize(records) - 1; a++)
   {
      for(int b = a + 1; b < ArraySize(records); b++)
      {
         if(records[b].closeTime > records[a].closeTime)
         {
            ClosedPositionResult temp = records[a];
            records[a] = records[b];
            records[b] = temp;
         }
      }
   }

   return ArraySize(records);
}

int TodayConsecutiveLosses()
{
   ClosedPositionResult records[];
   int count = TodayClosedPositionResults(records);
   int losses = 0;

   for(int i = 0; i < count; i++)
   {
      if(records[i].netResult < -0.01)
         losses++;
      else if(records[i].netResult > 0.01)
         break; // A profitable position resets the current loss streak.
      // Near-zero results do not increase or reset the streak.
   }
   return losses;
}

bool DailyLimitsAllowNewTrade()
{
   double dailyProfit = TodayStrategyProfit();
   double maxLossMoney = AccountInfoDouble(ACCOUNT_BALANCE)
                         * InpDailyLossLimitPercent / 100.0;

   if(dailyProfit <= -maxLossMoney)
   {
      Print("Daily loss limit reached. New trades are blocked. P/L=",
            DoubleToString(dailyProfit, 2));
      return false;
   }

   int tradesToday = TodayEntryCount();
   if(tradesToday >= InpMaxTradesPerDay)
   {
      Print("Maximum daily trade count reached: ", tradesToday);
      return false;
   }

   int lossStreak = TodayConsecutiveLosses();
   if(lossStreak >= InpMaxConsecutiveLosses)
   {
      Print("Maximum consecutive losses reached: ", lossStreak);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Volume sizing and margin protection                              |
//+------------------------------------------------------------------+
int VolumeDigitsFromStep(double step)
{
   for(int digits = 0; digits <= 8; digits++)
   {
      if(MathAbs(step - NormalizeDouble(step, digits)) < 0.00000001)
         return digits;
   }
   return 8;
}

double CalculateRiskVolume(const ENUM_ORDER_TYPE orderType,
                           const double entryPrice,
                           const double stopPrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   if(balance <= 0.0 || riskMoney <= 0.0)
      return 0.0;

   double oneLotProfit = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0,
                       entryPrice, stopPrice, oneLotProfit))
   {
      Print("OrderCalcProfit failed. Error=", GetLastError());
      return 0.0;
   }

   double oneLotLoss = MathAbs(oneLotProfit);
   if(oneLotLoss <= 0.0)
      return 0.0;

   double rawVolume = riskMoney / oneLotLoss;

   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volumeStep <= 0.0 || minVolume <= 0.0)
      return 0.0;

   // Round DOWN to avoid exceeding the planned risk.
   double volume = MathFloor(rawVolume / volumeStep + 1e-9) * volumeStep;
   volume = NormalizeDouble(volume, VolumeDigitsFromStep(volumeStep));

   // Never force the broker minimum if it exceeds the risk budget.
   if(volume < minVolume - 1e-9)
   {
      Print("Trade skipped: calculated volume ", rawVolume,
            " is below broker minimum ", minVolume,
            ". Minimum lot may exceed the $ risk limit.");
      return 0.0;
   }

   volume = MathMin(volume, maxVolume);
   volume = NormalizeDouble(volume, VolumeDigitsFromStep(volumeStep));

   double marginRequired = 0.0;
   double priceForMargin = entryPrice;
   if(!OrderCalcMargin(orderType, _Symbol, volume,
                       priceForMargin, marginRequired))
   {
      Print("OrderCalcMargin failed. Error=", GetLastError());
      return 0.0;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double reserve = equity * InpMinFreeMarginPercent / 100.0;

   if(freeMargin - marginRequired < reserve)
   {
      Print("Trade skipped: insufficient free margin reserve. Required=",
            DoubleToString(marginRequired, 2),
            ", free margin=", DoubleToString(freeMargin, 2));
      return 0.0;
   }

   return volume;
}

//+------------------------------------------------------------------+
//| Signal detection                                                 |
//+------------------------------------------------------------------+
bool GetSignal(bool &buySignal, bool &sellSignal)
{
   buySignal = false;
   sellSignal = false;

   MqlRates rates[];
   ArrayResize(rates, 3);
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, 3, rates) != 3)
      return false;

   double ema[];
   ArrayResize(ema, 3);
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(emaHandle, 0, 0, 3, ema) != 3)
      return false;

   // rates[1] is the most recently closed candle; rates[2] is the one before it.
   bool previousBearish = (rates[2].close < rates[2].open);
   bool previousBullish = (rates[2].close > rates[2].open);
   bool currentBullish  = (rates[1].close > rates[1].open);
   bool currentBearish  = (rates[1].close < rates[1].open);

   bool bullishEngulfing =
      previousBearish && currentBullish &&
      rates[1].open <= rates[2].close &&
      rates[1].close >= rates[2].open;

   bool bearishEngulfing =
      previousBullish && currentBearish &&
      rates[1].open >= rates[2].close &&
      rates[1].close <= rates[2].open;

   buySignal  = bullishEngulfing && rates[1].close > ema[1];
   sellSignal = bearishEngulfing && rates[1].close < ema[1];

   return true;
}

//+------------------------------------------------------------------+
//| Position management                                              |
//+------------------------------------------------------------------+
bool ModifyPositionSL(const ulong ticket, const double newSL,
                      const double currentTP)
{
   double normalizedSL = NormalizeDouble(newSL, _Digits);
   bool ok = trade.PositionModify(ticket, normalizedSL, currentTP);
   uint retcode = trade.ResultRetcode();

   if(!ok || (retcode != TRADE_RETCODE_DONE &&
              retcode != TRADE_RETCODE_NO_CHANGES))
   {
      Print("Position SL modification failed. Ticket=", ticket,
            ", retcode=", retcode, " ", trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

void ManageOpenPositions()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double pip = PipSize();
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistance = MathMax(stopsLevel, freezeLevel) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double marketPrice = (type == POSITION_TYPE_BUY) ? tick.bid : tick.ask;

      double profitPips = (type == POSITION_TYPE_BUY)
                          ? (marketPrice - openPrice) / pip
                          : (openPrice - marketPrice) / pip;

      double desiredSL = currentSL;
      bool shouldModify = false;

      // Break-even: lock a small positive amount once trigger is reached.
      if(profitPips >= InpBreakEvenTriggerPips)
      {
         double beSL = (type == POSITION_TYPE_BUY)
                       ? openPrice + InpBreakEvenLockPips * pip
                       : openPrice - InpBreakEvenLockPips * pip;

         if(type == POSITION_TYPE_BUY)
         {
            if((currentSL == 0.0 || beSL > desiredSL) &&
               marketPrice - beSL >= minDistance)
            {
               desiredSL = beSL;
               shouldModify = true;
            }
         }
         else
         {
            if((currentSL == 0.0 || beSL < desiredSL) &&
               beSL - marketPrice >= minDistance)
            {
               desiredSL = beSL;
               shouldModify = true;
            }
         }
      }

      // Trailing stop: only moves the stop in the profitable direction.
      if(profitPips >= InpTrailingStartPips)
      {
         double trailSL = (type == POSITION_TYPE_BUY)
                          ? marketPrice - InpTrailingDistancePips * pip
                          : marketPrice + InpTrailingDistancePips * pip;

         if(type == POSITION_TYPE_BUY)
         {
            if((desiredSL == 0.0 || trailSL > desiredSL) &&
               marketPrice - trailSL >= minDistance)
            {
               desiredSL = trailSL;
               shouldModify = true;
            }
         }
         else
         {
            if((desiredSL == 0.0 || trailSL < desiredSL) &&
               trailSL - marketPrice >= minDistance)
            {
               desiredSL = trailSL;
               shouldModify = true;
            }
         }
      }

      if(shouldModify && MathAbs(desiredSL - currentSL) >= _Point)
         ModifyPositionSL(ticket, desiredSL, currentTP);
   }
}

//+------------------------------------------------------------------+
//| Order placement                                                  |
//+------------------------------------------------------------------+
bool TradeResultSuccessful()
{
   uint code = trade.ResultRetcode();
   return (code == TRADE_RETCODE_DONE ||
           code == TRADE_RETCODE_DONE_PARTIAL ||
           code == TRADE_RETCODE_PLACED);
}

bool HasOurOpenPosition()
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

void OpenTrade(const ENUM_ORDER_TYPE orderType)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double pip = PipSize();
   double entry = (orderType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = (orderType == ORDER_TYPE_BUY)
               ? entry - InpStopLossPips * pip
               : entry + InpStopLossPips * pip;
   double tp = (orderType == ORDER_TYPE_BUY)
               ? entry + InpTakeProfitPips * pip
               : entry - InpTakeProfitPips * pip;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * _Point;

   if(MathAbs(entry - sl) < minStopDistance ||
      MathAbs(tp - entry) < minStopDistance)
   {
      Print("Trade skipped: SL/TP is closer than broker minimum stop distance.");
      return;
   }

   double volume = CalculateRiskVolume(orderType, entry, sl);
   if(volume <= 0.0)
      return;

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   bool sent = false;
   if(orderType == ORDER_TYPE_BUY)
      sent = trade.Buy(volume, _Symbol, 0.0, sl, tp, "EngulfingProBot BUY");
   else
      sent = trade.Sell(volume, _Symbol, 0.0, sl, tp, "EngulfingProBot SELL");

   if(!sent || !TradeResultSuccessful())
   {
      Print("Order failed. Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return;
   }

   Print("Order accepted: ",
         (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         ", volume=", DoubleToString(volume, 2),
         ", planned risk=", DoubleToString(
            AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0, 2),
         ", SL=", DoubleToString(sl, _Digits),
         ", TP=", DoubleToString(tp, _Digits));
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 2.0 ||
      InpStopLossPips <= 0 || InpTakeProfitPips <= 0 ||
      InpEMAPeriod < 2 || InpMaxTradesPerDay < 1 ||
      InpMaxConsecutiveLosses < 1 ||
      InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour < 0 || InpSessionEndHour > 23)
   {
      Print("Invalid input parameters. Check risk, SL/TP, EMA, limits and session.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsEURUSDSymbol())
   {
      Print("This EA is restricted to EURUSD symbols. Current symbol: ", _Symbol);
      return INIT_FAILED;
   }

   emaHandle = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicator. Error=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   lastBarTime = iTime(_Symbol, _Period, 0);

   Print("EngulfingProBot v4.10 initialized on ", _Symbol,
         ". Use Strategy Tester and a demo account before live trading.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // Always manage existing positions, even outside entry session.
   ManageOpenPositions();

   if(!IsNewBar())
      return;

   if(!IsEURUSDSymbol())
      return;

   if(!IsTradingSession())
      return;

   if(CurrentSpreadPips() > InpMaxSpreadPips)
   {
      Print("Signal ignored: spread is above ",
            DoubleToString(InpMaxSpreadPips, 1), " pips.");
      return;
   }

   if(!DailyLimitsAllowNewTrade())
      return;

   if(InpOnePositionAtATime && HasOurOpenPosition())
      return;

   bool buySignal = false;
   bool sellSignal = false;
   if(!GetSignal(buySignal, sellSignal))
   {
      Print("Could not read candle/EMA data yet.");
      return;
   }

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL);
}
//+------------------------------------------------------------------+
