//+------------------------------------------------------------------+
//|                                               GoldDeskSync.mq5   |
//|   Envoie les positions fermees de MT5 vers le journal Gold Desk. |
//|   Ne passe AUCUN ordre. Lecture de l'historique uniquement.      |
//+------------------------------------------------------------------+
#property copyright "Gold Desk"
#property version   "1.00"
#property strict
#property description "Synchronise l'historique des trades fermes vers le journal Gold Desk."
#property description "N'ouvre et ne ferme aucune position."

//--- Parametres -----------------------------------------------------
input string InpSyncCode   = "";           // Code de sync du journal (XXXX-XXXX-XX)
input int    InpBackfillDays = 90;         // Jours d'historique a rattraper au demarrage
input int    InpBrokerGmtOffset = 3;       // Decalage GMT du broker (PU Prime = 3)
input bool   InpVerbose    = true;         // Ecrire le detail dans l'onglet Experts

//--- Constantes -----------------------------------------------------
#define GD_URL "https://uwxabpwyilqkbcowwgou.supabase.co/rest/v1/mt5_deals?on_conflict=code,ticket"
#define GD_KEY "sb_publishable_ojOK45dAjHTyRJtq1SVJqQ_JKvNNX57"
#define GD_BATCH 40

string g_code = "";
string g_gvar = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   g_code = NormalizeCode(InpSyncCode);
   if(StringLen(g_code) != 12)
     {
      Print("Gold Desk : code de sync invalide. Attendu XXXX-XXXX-XX, recu \"", InpSyncCode, "\".");
      Print("Gold Desk : ouvre le journal -> Sync -> copie le code, puis colle-le dans les parametres de l'EA.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_gvar = "GoldDesk_LastClose_" + g_code;

   if(!MQLInfoInteger(MQL_WEBREQUEST_ENABLED) && !TerminalInfoInteger(TERMINAL_DLLS_ALLOWED))
      Print("Gold Desk : si tu vois une erreur 4014/4060, autorise l'URL dans "
            "Outils > Options > Expert Advisors > Autoriser WebRequest, et ajoute "
            "https://uwxabpwyilqkbcowwgou.supabase.co");

   datetime from = (datetime)(TimeCurrent() - (datetime)InpBackfillDays * 86400);
   datetime last = (datetime)GlobalVariableGet(g_gvar);
   if(last > from) from = last;

   Print("Gold Desk : demarrage. Rattrapage depuis ", TimeToString(from, TIME_DATE|TIME_MINUTES));
   SyncSince(from);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }

//--- Rien a faire sur chaque tick : on ne trade pas.
void OnTick() { }

//+------------------------------------------------------------------+
//| Declenche a chaque changement de l'historique : une cloture y est |
//| incluse, donc on resynchronise la fenetre recente.                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;

   if(!HistoryDealSelect(trans.deal)) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   datetime last = (datetime)GlobalVariableGet(g_gvar);
   datetime from = (last > 0) ? (datetime)(last - 3600) : (datetime)(TimeCurrent() - 86400);
   SyncSince(from);
  }

//+------------------------------------------------------------------+
//| Coeur : agrege les positions fermees depuis `from` et les envoie. |
//+------------------------------------------------------------------+
void SyncSince(datetime from)
  {
   if(!HistorySelect(from, TimeCurrent() + 86400))
     {
      Print("Gold Desk : lecture de l'historique impossible.");
      return;
     }

   ulong    posIds[];
   datetime posClose[];
   int      n = 0;
   int      deals = HistoryDealsTotal();

   for(int i = 0; i < deals; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;

      long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // ignore balance/credit

      ulong pid = (ulong)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      if(pid == 0) continue;

      bool seen = false;
      for(int k = 0; k < n; k++) if(posIds[k] == pid) { seen = true; break; }
      if(seen) continue;

      ArrayResize(posIds,   n + 1);
      ArrayResize(posClose, n + 1);
      posIds[n]   = pid;
      posClose[n] = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      n++;
     }

   if(n == 0) { if(InpVerbose) Print("Gold Desk : rien de nouveau."); return; }

   string   batch    = "";
   int      inBatch  = 0;
   int      sent     = 0;
   datetime maxClose = (datetime)GlobalVariableGet(g_gvar);

   for(int i = 0; i < n; i++)
     {
      string row = BuildRow(posIds[i]);
      if(row == "") continue;

      if(inBatch > 0) batch += ",";
      batch += row;
      inBatch++;

      if(posClose[i] > maxClose) maxClose = posClose[i];

      if(inBatch >= GD_BATCH)
        {
         if(PostBatch(batch, inBatch)) sent += inBatch;
         batch = ""; inBatch = 0;
        }
     }

   if(inBatch > 0 && PostBatch(batch, inBatch)) sent += inBatch;

   if(sent > 0)
     {
      GlobalVariableSet(g_gvar, (double)maxClose);
      Print("Gold Desk : ", sent, " trade(s) envoyes au journal.");
     }
  }

//+------------------------------------------------------------------+
//| Construit un objet JSON pour une position fermee.                 |
//+------------------------------------------------------------------+
string BuildRow(ulong posId)
  {
   if(!HistorySelectByPosition(posId)) return("");

   int      deals   = HistoryDealsTotal();
   double   volIn = 0, volOut = 0, priceIn = 0, priceOut = 0;
   double   profit = 0, commission = 0, swap = 0, fee = 0;
   double   sl = 0, tp = 0;
   datetime tOpen = 0, tClose = 0;
   string   symbol = "";
   long     dir = -1;

   for(int i = 0; i < deals; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;

      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

      long   entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      double vol   = HistoryDealGetDouble(t, DEAL_VOLUME);
      double price = HistoryDealGetDouble(t, DEAL_PRICE);

      profit     += HistoryDealGetDouble(t, DEAL_PROFIT);
      commission += HistoryDealGetDouble(t, DEAL_COMMISSION);
      swap       += HistoryDealGetDouble(t, DEAL_SWAP);
      fee        += HistoryDealGetDouble(t, DEAL_FEE);

      if(symbol == "") symbol = HistoryDealGetString(t, DEAL_SYMBOL);

      if(entry == DEAL_ENTRY_IN)
        {
         priceIn += price * vol;
         volIn   += vol;
         if(tOpen == 0) tOpen = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
         if(dir < 0)    dir   = (type == DEAL_TYPE_BUY) ? 0 : 1;   // 0 = buy, 1 = sell
        }
      else
        {
         priceOut += price * vol;
         volOut   += vol;
         datetime tc = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
         if(tc > tClose) tClose = tc;
         if(sl == 0) sl = HistoryDealGetDouble(t, DEAL_SL);
         if(tp == 0) tp = HistoryDealGetDouble(t, DEAL_TP);
        }
     }

   if(volIn <= 0 || volOut <= 0 || tClose == 0) return("");

   double avgIn  = priceIn  / volIn;
   double avgOut = priceOut / volOut;
   double net    = NormalizeDouble(profit + commission + swap + fee, 2);
   double costs  = MathAbs(MathMin(0.0, commission + swap + fee));

   // Le journal veut XAUUSD, pas XAUUSD.s
   string sym = CleanSymbol(symbol);

   int hOpen = (int)(((tOpen % 86400) / 3600) + 24) % 24;
   string session = SessionFromHour(hOpen);

   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits <= 0) digits = 2;
   int    dur    = (tClose > tOpen) ? (int)((tClose - tOpen) / 60) : 0;
   string ticket = IntegerToString((long)posId);

   string t = "{";
   t += "\"id\":\"t_mt5_" + ticket + "\",";
   t += "\"ticket\":\"" + ticket + "\",";
   t += "\"date\":\"" + DateOnly(tClose) + "\",";
   t += "\"setup\":\"\\u2014\",";
   t += "\"dir\":\"" + (dir == 1 ? "sell" : "buy") + "\",";
   t += "\"entry\":"  + DoubleToString(avgIn,  digits) + ",";
   t += "\"exit\":"   + DoubleToString(avgOut, digits) + ",";
   t += "\"sl\":"     + (sl > 0 ? DoubleToString(sl, digits) : "null") + ",";
   t += "\"tp\":"     + (tp > 0 ? DoubleToString(tp, digits) : "null") + ",";
   t += "\"lot\":"    + DoubleToString(volOut, 2) + ",";
   t += "\"risk\":null,\"riskAmt\":null,\"rr\":null,\"r\":null,";
   t += "\"symbol\":\"" + sym + "\",";
   t += "\"session\":\"" + session + "\",";
   t += "\"fees\":"   + DoubleToString(NormalizeDouble(costs, 2), 2) + ",";
   t += "\"dur\":"    + (dur > 0 ? IntegerToString(dur) : "null") + ",";
   t += "\"status\":\"closed\",";
   t += "\"pnl\":"    + DoubleToString(net, 2) + ",";
   t += "\"source\":\"mt5\",";
   t += "\"createdAt\":" + IntegerToString((long)tClose * 1000) + ",";
   t += "\"closedAt\":"  + IntegerToString((long)tClose * 1000);
   t += "}";

   string row = "{";
   row += "\"code\":\""   + g_code + "\",";
   row += "\"ticket\":\"" + ticket + "\",";
   row += "\"data\":"     + t;
   row += "}";
   return(row);
  }

//+------------------------------------------------------------------+
bool PostBatch(string rows, int count)
  {
   char   body[], result[];
   string headers = "apikey: " + GD_KEY + "\r\n"
                    "Authorization: Bearer " + GD_KEY + "\r\n"
                    "Content-Type: application/json\r\n"
                    "Prefer: resolution=merge-duplicates,return=minimal\r\n";
   string payload = "[" + rows + "]";
   string resHeaders;

   StringToCharArray(payload, body, 0, StringLen(payload), CP_UTF8);
   ArrayResize(body, ArraySize(body) - 1);   // pas de \0 final

   ResetLastError();
   int code = WebRequest("POST", GD_URL, headers, 15000, body, result, resHeaders);

   if(code == -1)
     {
      int err = GetLastError();
      Print("Gold Desk : envoi impossible (erreur ", err, ").");
      if(err == 4014 || err == 4060)
         Print("Gold Desk : autorise l'URL dans Outils > Options > Expert Advisors > "
               "Autoriser WebRequest pour les URL listees, puis ajoute "
               "https://uwxabpwyilqkbcowwgou.supabase.co");
      return(false);
     }

   if(code >= 200 && code < 300)
     {
      if(InpVerbose) Print("Gold Desk : lot de ", count, " trade(s) accepte (HTTP ", code, ").");
      return(true);
     }

   Print("Gold Desk : le serveur a refuse (HTTP ", code, ") : ",
         CharArrayToString(result, 0, MathMin(300, ArraySize(result))));
   return(false);
  }

//+------------------------------------------------------------------+
//| Utilitaires                                                       |
//+------------------------------------------------------------------+
string NormalizeCode(string raw)
  {
   string up = raw;
   StringToUpper(up);
   string only = "";
   for(int i = 0; i < StringLen(up); i++)
     {
      ushort c = StringGetCharacter(up, i);
      if((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z'))
         only += ShortToString(c);
     }
   if(StringLen(only) != 10) return("");
   return(StringSubstr(only, 0, 4) + "-" + StringSubstr(only, 4, 4) + "-" + StringSubstr(only, 8, 2));
  }

string CleanSymbol(string s)
  {
   string up = s;
   StringToUpper(up);
   int dot = StringFind(up, ".");
   if(dot > 0) up = StringSubstr(up, 0, dot);
   int us = StringFind(up, "_");
   if(us > 0) up = StringSubstr(up, 0, us);
   int hash = StringFind(up, "#");
   if(hash > 0) up = StringSubstr(up, 0, hash);
   if(StringLen(up) == 0) up = "XAUUSD";
   return(up);
  }

string SessionFromHour(int h)
  {
   if(h < 10) return("Asia");
   if(h < 15) return("London");
   if(h < 18) return("Overlap");
   return("New York");
  }

string DateOnly(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return(StringFormat("%04d-%02d-%02d", d.year, d.mon, d.day));
  }
//+------------------------------------------------------------------+
