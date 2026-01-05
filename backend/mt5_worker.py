import MetaTrader5 as mt5
import multiprocessing
import time
from datetime import datetime
import traceback
import queue

class MT5Worker(multiprocessing.Process):
    def __init__(self, worker_id, terminal_path, command_queue, result_queue):
        super().__init__()
        self.worker_id = worker_id
        self.terminal_path = terminal_path
        self.command_queue = command_queue
        self.result_queue = result_queue
        self.running = True
        self.current_account = None

    def run(self):
        print(f"[Worker {self.worker_id}] Starting... Path: {self.terminal_path}")
        
        # Initialize MT5 specific to this worker (Process Isolated)
        try:
            if not mt5.initialize(path=self.terminal_path):
                self.result_queue.put({"status": "error", "detail": f"Init failed: {mt5.last_error()}"})
                return
            print(f"[Worker {self.worker_id}] MT5 Initialized.")
        except Exception as e:
            self.result_queue.put({"status": "error", "detail": f"Init Exception: {e}"})
            return

        while self.running:
            try:
                # Wait for command with timeout to allow checking self.running
                try:
                    command = self.command_queue.get(timeout=1)
                except queue.Empty:
                    continue

                cmd_type = command.get("type")
                request_id = command.get("id")
                
                if cmd_type == "STOP":
                    self.running = False
                    break

                # Process Command
                result = None
                try:
                    if cmd_type == "LOGIN":
                        result = self._handle_login(command["data"])
                    elif cmd_type == "TRADE":
                        result = self._handle_trade(command["data"])
                    elif cmd_type == "MODIFY":
                        result = self._handle_modify(command["data"])
                    elif cmd_type == "CLOSE":
                        result = self._handle_close(command["data"])
                    elif cmd_type == "HISTORY":
                        result = self._handle_history(command["data"])
                    elif cmd_type == "POSITIONS":
                        result = self._handle_positions()
                    elif cmd_type == "ACCOUNT_INFO":
                        result = self._handle_account_info()
                    elif cmd_type == "TICKS":
                        result = self._handle_ticks(command["data"])
                    elif cmd_type == "TRADE_HISTORY":
                        result = self._handle_trade_history(command["data"])
                    else:
                         result = {"status": "error", "detail": "Unknown command"}
                except Exception as e:
                    print(f"[Worker {self.worker_id}] Error processing {cmd_type}: {e}")
                    traceback.print_exc()
                    result = {"status": "error", "detail": str(e)}

                # Send Result
                response = {"id": request_id, "result": result}
                self.result_queue.put(response)

            except Exception as e:
                 print(f"[Worker {self.worker_id}] Loop Error: {e}")

        mt5.shutdown()
        print(f"[Worker {self.worker_id}] Shutdown.")

    def _handle_login(self, data):
        login = int(data['login'])
        password = data['password']
        server = data['server']
        
        if not mt5.login(login=login, password=password, server=server):
             return {"status": "error", "detail": f"Login failed: {mt5.last_error()}"}
        
        self.current_account = login
        return {"status": "success", "detail": f"Logged in as {login}"}

    def _handle_trade(self, item):
        # ... Reuse logic from main.py ...
        symbol = item['symbol']
        if not mt5.symbol_select(symbol, True):
             return {"status": "error", "detail": "Symbol select failed"}

        action = mt5.TRADE_ACTION_DEAL
        order_type = mt5.ORDER_TYPE_BUY if item['action'] == "BUY" else mt5.ORDER_TYPE_SELL
        price = 0.0

        if item.get('order_mode', 'MARKET') == 'LIMIT':
             action = mt5.TRADE_ACTION_PENDING
             price = item['price']
             tick = mt5.symbol_info_tick(symbol)
             if not tick: return {"status": "error", "detail": "Tick not found"}
             
             if item['action'] == "BUY":
                 order_type = mt5.ORDER_TYPE_BUY_LIMIT if price < tick.ask else mt5.ORDER_TYPE_BUY_STOP
             else:
                 order_type = mt5.ORDER_TYPE_SELL_LIMIT if price > tick.bid else mt5.ORDER_TYPE_SELL_STOP
        else:
             tick = mt5.symbol_info_tick(symbol)
             if not tick: return {"status": "error", "detail": "Tick not found"}
             price = tick.ask if item['action'] == "BUY" else tick.bid

        request = {
            "action": action,
            "symbol": symbol,
            "volume": item['volume'],
            "type": order_type,
            "price": price,
            "sl": item.get('sl', 0.0),
            "tp": item.get('tp', 0.0),
            "magic": 234000,
            "comment": "FlutterWorker",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }
        
        res = mt5.order_send(request)
        if res.retcode != mt5.TRADE_RETCODE_DONE:
             return {"status": "error", "detail": f"Order failed: {res.comment}"}
        return {"status": "success", "ticket": res.order}

    def _handle_modify(self, item):
        # ... Reuse logic ...
        req = None
        # Try open position
        positions = mt5.positions_get(ticket=item['ticket'])
        if positions:
             req = {
                 "action": mt5.TRADE_ACTION_SLTP,
                 "position": item['ticket'],
                 "symbol": item['symbol'],
                 "sl": item['sl'],
                 "tp": item['tp']
             }
        else:
             orders = mt5.orders_get(ticket=item['ticket'])
             if orders:
                 o = orders[0]
                 req = {
                     "action": mt5.TRADE_ACTION_MODIFY,
                     "order": item['ticket'],
                     "symbol": item['symbol'],
                     "sl": item['sl'],
                     "tp": item['tp'],
                     "price": o.price_open, # Helper logic needed to keep open price?
                     "type": o.type
                 }
        
        if not req: return {"status": "error", "detail": "Ticket not found"}
        res = mt5.order_send(req)
        if res.retcode != mt5.TRADE_RETCODE_DONE:
             return {"status": "error", "detail": res.comment}
        return {"status": "success", "ticket": res.order}

    def _handle_close(self, item):
         ticket = item['ticket']
         symbol = item['symbol']
         if not mt5.symbol_select(symbol, True): return {"status": "error", "detail": "Symbol error"}
         
         positions = mt5.positions_get(ticket=ticket)
         if positions:
             pos = positions[0]
             # Close
             order_type = mt5.ORDER_TYPE_SELL if pos.type == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_BUY
             tick = mt5.symbol_info_tick(symbol)
             price = tick.bid if pos.type == mt5.ORDER_TYPE_BUY else tick.ask
             
             req = {
                 "action": mt5.TRADE_ACTION_DEAL,
                 "symbol": symbol,
                 "volume": pos.volume,
                 "type": order_type,
                 "position": ticket,
                 "price": price,
                 "magic": 234000
             }
         else:
             orders = mt5.orders_get(ticket=ticket)
             if orders:
                 req = {"action": mt5.TRADE_ACTION_REMOVE, "order": ticket}
             else:
                 return {"status": "error", "detail": "Not found"}

         res = mt5.order_send(req)
         if res.retcode != mt5.TRADE_RETCODE_DONE: return {"status": "error", "detail": res.comment}
         return {"status": "success", "ticket": res.order}

    def _handle_positions(self):
        # Returns raw list of dicts for JSON serialization
        # (Must convert MT5 objects to dicts)
        # Similar logic to main.py get_positions
        # ... logic omitted for brevity, will implement fully ...
        data = []
        positions = mt5.positions_get()
        if positions:
             for p in positions:
                 data.append({
                     "ticket": p.ticket,
                     "symbol": p.symbol,
                     "type": "BUY" if p.type == mt5.ORDER_TYPE_BUY else "SELL",
                     "volume": p.volume,
                     "price_open": p.price_open,
                     "price_current": p.price_current,
                     "sl": p.sl, "tp": p.tp, "profit": p.profit,
                     "time": p.time, # timestamp
                     "status": "OPEN",
                     "tick_value": 0.0, # Optimize: don't fetch symbol_info for every pos in worker loop, or do it?
                     "tick_size": 0.0   # Fast enough usually
                 })
                 
        orders = mt5.orders_get()
        if orders:
             for o in orders:
                 type_str = "LIMIT"
                 t = o.type
                 if t == mt5.ORDER_TYPE_BUY_LIMIT: type_str = "BUY LIMIT"
                 elif t == mt5.ORDER_TYPE_SELL_LIMIT: type_str = "SELL LIMIT"
                 elif t == mt5.ORDER_TYPE_BUY_STOP: type_str = "BUY STOP"
                 elif t == mt5.ORDER_TYPE_SELL_STOP: type_str = "SELL STOP"
                 else: type_str = "ORDER"
                 # ...
                 data.append({
                     "ticket": o.ticket,
                     "symbol": o.symbol,
                     "type": type_str,
                     "volume": o.volume_initial,
                     "price_open": o.price_open,
                     "price_current": 0.0,
                     "sl": o.sl, "tp": o.tp, "profit": 0.0,
                     "time": o.time_setup,
                     "status": "PENDING"
                 })
        return data

    def _handle_account_info(self):
        v = mt5.account_info()
        if not v: return None
        return v._asdict()

    def _handle_history(self, data):
        symbol = data.get('symbol')
        timeframe = data.get('timeframe', 'M1')
        count = int(data.get('count', 300))
        
        tf_map = {
            "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
            "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
            "D1": mt5.TIMEFRAME_D1, "W1": mt5.TIMEFRAME_W1, "MN1": mt5.TIMEFRAME_MN1
        }
        
        mt5_tf = tf_map.get(timeframe, mt5.TIMEFRAME_M1)
        
        # Ensure symbol is ready
        if not mt5.symbol_select(symbol, True):
             return {"status": "error", "detail": f"Symbol {symbol} select failed (History)"}
             
        rates = mt5.copy_rates_from_pos(symbol, mt5_tf, 0, count)
        
        if rates is None:
             return {"status": "error", "detail": f"Failed to get history for {symbol}"}
             
        data_list = []
        for rate in rates:
            data_list.append({
                "time": int(rate['time']),
                "open": float(rate['open']),
                "high": float(rate['high']),
                "low": float(rate['low']),
                "close": float(rate['close']),
                "tick_volume": int(rate['tick_volume'])
            })
            
        return {"status": "success", "data": data_list}
    
    def _handle_ticks(self, symbols):
        # Return dict of {symbol: {bid, ask...}}
        res = {}
        for s in symbols:
             tick = mt5.symbol_info_tick(s)
             
             # If tick not found, try selecting it (forces allow in MarketWatch)
             if tick is None:
                 if mt5.symbol_select(s, True):
                     tick = mt5.symbol_info_tick(s)
                     
             if tick:
                 res[s] = {"bid": tick.bid, "ask": tick.ask, "time": tick.time}
             else:
                 # Return 0s if really not found (e.g. invalid symbol)
                 res[s] = {"bid": 0.0, "ask": 0.0, "time": 0}
        
        return res

    def _handle_trade_history(self, data):
        try:
            # Handle string dates safely
            fd = data.get('from_date')
            td = data.get('to_date')
            
            # Helper to parse or default
            def parse_date(d_str, default_val):
                if not d_str: return default_val
                try:
                    # Remove 'Z' or offset if present for simplicity, or use fromisoformat
                    return datetime.fromisoformat(d_str.replace('Z', '+00:00'))
                except:
                    return default_val

            from_date = parse_date(fd, datetime(2023, 1, 1))
            to_date = parse_date(td, datetime.now()) # + 1 day?
            
            group = data.get('group', 'DEALS')
            
            res_tuple = None
            if group == "ORDERS":
                try:
                    res_tuple = mt5.history_orders_get(from_date, to_date)
                except: pass
            else:
                try:
                    res_tuple = mt5.history_deals_get(from_date, to_date)
                except: pass
                
            if res_tuple is None:
                 err = mt5.last_error()
                 if err[0] == 1: 
                     return {"status": "success", "summary": {}, "deals": [], "orders": []}
                 return {"status": "error", "detail": f"MT5 History Error: {err}"}
                 
            data_list = []
            summary = {"profit": 0.0, "commission": 0.0, "swap": 0.0, "balance": 0.0, "deposit": 0.0}

            if group == "POSITIONS":
                # Aggregate Deals into Positions
                deals_by_id = {}
                try:
                    all_deals = mt5.history_deals_get(from_date, to_date)
                    if all_deals:
                        for d in all_deals:
                            pid = d.position_id
                            if pid not in deals_by_id: deals_by_id[pid] = []
                            deals_by_id[pid].append(d)
                        
                        for pid, deals in deals_by_id.items():
                            deals.sort(key=lambda x: x.time)
                            
                            # Filter for closed positions (must have an ENTRY_OUT)
                            has_out = any(d.entry == mt5.DEAL_ENTRY_OUT or d.entry == mt5.DEAL_ENTRY_OUT_BY for d in deals)
                            if not has_out: continue
                            
                            entry_deal = next((d for d in deals if d.entry == mt5.DEAL_ENTRY_IN), deals[0])
                            exit_deal = next((d for d in reversed(deals) if d.entry == mt5.DEAL_ENTRY_OUT or d.entry == mt5.DEAL_ENTRY_OUT_BY), deals[-1])
                            
                            gross_profit = sum(d.profit for d in deals)
                            total_commission = sum(d.commission for d in deals)
                            total_swap = sum(d.swap for d in deals)
                            
                            # Type string
                            type_str = "BUY" if entry_deal.type == mt5.DEAL_TYPE_BUY else "SELL"
                            
                            pos_data = {
                                "ticket": pid,
                                "symbol": entry_deal.symbol,
                                "type": type_str,
                                "volume": entry_deal.volume,
                                "open_time": entry_deal.time,
                                "close_time": exit_deal.time,
                                "open_price": entry_deal.price,
                                "close_price": exit_deal.price,
                                "profit": gross_profit,
                                "commission": total_commission,
                                "swap": total_swap,
                                "net_profit": gross_profit + total_commission + total_swap,
                                "time": exit_deal.time # Sort by close time
                            }
                            data_list.append(pos_data)
                            
                            summary['profit'] += gross_profit
                            # Note: Commission/Swap already in total_profit for list logic, 
                            # but for summary breakdown we might want raw sums?
                            # Let's sum raw for breakdown:
                            summary['commission'] += total_commission
                            summary['swap'] += total_swap

                except Exception as e:
                    traceback.print_exc()

            else:
                for item in res_tuple:
                    d = item._asdict()
                    
                    # Convert Enums to Strings
                    if group == "DEALS":
                        summary['profit'] += d.get('profit', 0.0)
                        summary['commission'] += d.get('commission', 0.0)
                        summary['swap'] += d.get('swap', 0.0)
                        
                        t = d.get('type')
                        if t == mt5.DEAL_TYPE_BUY: d['type'] = "BUY"
                        elif t == mt5.DEAL_TYPE_SELL: d['type'] = "SELL"
                        elif t == mt5.DEAL_TYPE_BALANCE: d['type'] = "BALANCE"
                        elif t == mt5.DEAL_TYPE_CREDIT: d['type'] = "CREDIT"
                        else: d['type'] = str(t)
    
                    elif group == "ORDERS":
                        t = d.get('type')
                        if t == mt5.ORDER_TYPE_BUY: d['type'] = "BUY"
                        elif t == mt5.ORDER_TYPE_SELL: d['type'] = "SELL"
                        elif t == mt5.ORDER_TYPE_BUY_LIMIT: d['type'] = "BUY LIMIT"
                        elif t == mt5.ORDER_TYPE_SELL_LIMIT: d['type'] = "SELL LIMIT"
                        elif t == mt5.ORDER_TYPE_BUY_STOP: d['type'] = "BUY STOP"
                        elif t == mt5.ORDER_TYPE_SELL_STOP: d['type'] = "SELL STOP"
                        else: d['type'] = str(t)
                        
                        s = d.get('state')
                        if s == mt5.ORDER_STATE_FILLED: d['state'] = "FILLED"
                        elif s == mt5.ORDER_STATE_CANCELED: d['state'] = "CANCELED"
                        elif s == mt5.ORDER_STATE_PLACED: d['state'] = "PLACED"
                        else: d['state'] = str(s)
    
                    data_list.append(d)
                
            data_list.sort(key=lambda x: x['time'], reverse=True)
            
            return {
                "status": "success", 
                "summary": summary, 
                "deals": data_list if group == "DEALS" else [],
                "orders": data_list if group == "ORDERS" else [],
                "positions": data_list if group == "POSITIONS" else []
            } 
        except Exception as e:
            traceback.print_exc()
            return {"status": "error", "detail": str(e)}

        return res
