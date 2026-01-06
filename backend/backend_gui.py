import sys
import os
import json
import threading
import multiprocessing
import queue
import uuid
import time
import asyncio
import traceback
from datetime import datetime
from typing import Optional, Dict

# Third-party imports
from dotenv import load_dotenv
import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect, Query, Depends
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, 
                             QTabWidget, QTableWidget, QTableWidgetItem, QPushButton, 
                             QLabel, QLineEdit, QFormLayout, QMenu, QMessageBox, 
                             QSystemTrayIcon, QStyle, QFileDialog, QHeaderView,
                             QCheckBox, QDoubleSpinBox, QSpinBox, QDateTimeEdit)
from PyQt6.QtCore import Qt, QTimer, QThread, pyqtSignal, QDateTime, QObject, pyqtSlot
from PyQt6.QtGui import QAction, QIcon

# Ensure backend directory is in path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    from backend.mt5_worker import MT5Worker
    from backend.database import (init_db, create_or_update_user, get_user_by_app_login, 
                                  get_all_users, delete_user, get_sync_state, update_sync_state, reset_sync_state)
except ImportError:
    try:
        from mt5_worker import MT5Worker
        from database import (init_db, create_or_update_user, get_user_by_app_login, 
                              get_all_users, delete_user, get_sync_state, update_sync_state, reset_sync_state)
    except:
        pass

load_dotenv()

# One-time DB Init
init_db()

# === ASYNC WORKER MANAGER (NO ZOMBIES) ===
class AsyncWorkerManager:
    def __init__(self):
        self.workers: Dict[int, MT5Worker] = {}
        self.queues: Dict[int, tuple] = {} # (cmd_q, res_q)
        self.futures: Dict[str, asyncio.Future] = {} # { request_id : Future }
        self.loop = None
        self.running = True
        
        # Thread to consume all result queues
        self.listener_thread = threading.Thread(target=self._result_listener, daemon=True)
        self.listener_thread.start()

    def set_loop(self, loop):
        self.loop = loop

    def is_worker_running(self, mt5_login: int):
        return mt5_login in self.workers and self.workers[mt5_login].is_alive()

    def start_worker(self, mt5_login: int, path: str):
        if self.is_worker_running(mt5_login): return True
        
        if not os.path.exists(path):
            print(f"Terminal path not found: {path} for {mt5_login}")
            return False

        print(f"Starting Worker for MT5 {mt5_login} at {path}...")
        cmd_q = multiprocessing.Queue()
        res_q = multiprocessing.Queue()
        
        w = MT5Worker(worker_id=mt5_login, terminal_path=path, command_queue=cmd_q, result_queue=res_q)
        w.start()
        
        self.workers[mt5_login] = w
        self.queues[mt5_login] = (cmd_q, res_q)
        return True

    def stop_worker(self, mt5_login: int):
        if mt5_login in self.queues:
            try: self.queues[mt5_login][0].put({"type": "STOP"})
            except: pass
        
        if mt5_login in self.workers:
            w = self.workers[mt5_login]
            w.join(timeout=3)
            if w.is_alive(): w.terminate()
            del self.workers[mt5_login]
            del self.queues[mt5_login]
            print(f"Stopped Worker for {mt5_login}")

    def stop_all(self):
        self.running = False
        active_ids = list(self.workers.keys())
        for uid in active_ids: self.stop_worker(uid)

    def _result_listener(self):
        """
        Background thread that continously polls ALL result queues.
        Dispatches results to Futures. Discards zombies.
        """
        print("Async Result Listener Started")
        while self.running:
            # Iterate all active queues
            # Use list() to avoid runtime error if dict changes size
            active_logins = list(self.queues.keys()) 
            
            idle = True
            for login in active_logins:
                if login not in self.queues: continue
                _, res_q = self.queues[login]
                
                try:
                    # Non-blocking get
                    while not res_q.empty():
                        res = res_q.get_nowait()
                        idle = False
                        
                        req_id = res.get('id')
                        # Check if Future exists
                        if req_id and req_id in self.futures:
                            fut = self.futures.pop(req_id)
                            if not fut.done():
                                # Complete the future in the Event Loop safely
                                if self.loop:
                                    self.loop.call_soon_threadsafe(fut.set_result, res.get('result'))
                        else:
                            # ZOMBIE FOUND! Discard it.
                            # print(f"Discarding Zombie Response: {req_id}")
                            pass
                except:
                    pass
            
            if idle:
                time.sleep(0.01) # Low CPU usage wait

    async def execute(self, mt5_login: int, command_type, data=None, timeout=15):
        if not self.is_worker_running(mt5_login):
            return {"status": "error", "detail": "Worker not running"}
            
        cmd_q, _ = self.queues[mt5_login]
        request_id = str(uuid.uuid4())
        
        # Create Future
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self.futures[request_id] = fut
        
        # Send Command
        cmd = {"type": command_type, "id": request_id, "data": data}
        cmd_q.put(cmd)
        
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            # Cleanup future if timed out
            if request_id in self.futures:
                del self.futures[request_id]
            return {"status": "error", "detail": "Request timed out"}

manager = AsyncWorkerManager()

# === FASTAPI SERVER ===
app = FastAPI(title="MirrorTrade Backend (Optimized)", version="4.1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def app_startup():
    loop = asyncio.get_event_loop()
    manager.set_loop(loop)
    asyncio.create_task(sync_history_loop())
    
    # Auto-start valid users from DB
    users = get_all_users()
    for u in users:
        if u['is_active']:
            manager.start_worker(u['mt5_login'], u['mt5_path'])

# Models
class LoginRequest(BaseModel):
    login: str # Allows string for AppLogin
    password: str
    server: str

class TradeRequest(BaseModel):
    login: str # AppLogin
    action: str 
    symbol: str
    volume: float
    price: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    order_mode: str = "MARKET"

class ModifyRequest(BaseModel):
    login: str
    ticket: int
    symbol: str
    sl: float
    tp: float

class CloseRequest(BaseModel):
    login: str
    ticket: int
    symbol: str

class HistoryRequest(BaseModel):
    login: str
    from_date: Optional[str] = None
    to_date: Optional[str] = None
    group: str = "DEALS"

# Helpers to resolve AppLogin -> MT5Login
def resolve_user(app_login: str):
    u = get_user_by_app_login(app_login)
    if not u:
        raise HTTPException(400, "User not found")
    return u

# Endpoints

@app.post("/login")
async def login_mt5(item: LoginRequest):
    # 1. Check DB Logic
    u = get_user_by_app_login(item.login)
    
    if u:
        # DB Auth
        if u['app_password'] != item.password:
             raise HTTPException(401, "Invalid Password")
        
        # Ensure Worker Started
        manager.start_worker(u['mt5_login'], u['mt5_path'])
        
        # Call MT5 Login
        req = {
            "login": u['mt5_login'],
            "password": u['mt5_password'],
            "server": u['mt5_server']
        }
        res = await manager.execute(u['mt5_login'], "LOGIN", req)
        
        # Inject Virtual Config into response (optional)
        res['virtual_config'] = {
            "balance": u['virtual_start_balance'],
            "currency": "USD"
        }
        return res
    
    else:
        # Fallback to direct Mode (Legacy/Admin) if needed, or fail
        raise HTTPException(400, "User not configured in Database. Please contact Admin.")

@app.post("/trade")
async def place_trade(item: TradeRequest):
    u = resolve_user(item.login)
    mt5_id = u['mt5_login']
    
    # 0. Check Virtual Validation (RAM Check)
    # TODO: Implement fast RAM check using RAM_STATE
    
    # Advanced Logic
    req_vol = item.volume
    req_action = item.action
    req_sl = item.sl
    req_tp = item.tp
    
    multiplier = u['multiplier']
    if multiplier != 1.0:
        req_vol = round(req_vol * multiplier, 2)
        
    if u['mirror_enabled']:
        if req_action == "BUY": req_action = "SELL"
        elif req_action == "SELL": req_action = "BUY"
        req_sl, req_tp = req_tp, req_sl
        
    tag = f"[M:{1 if u['mirror_enabled'] else 0}|X:{multiplier}]"
    
    trade_data = item.dict()
    trade_data['action'] = req_action
    trade_data['volume'] = req_vol
    trade_data['sl'] = req_sl
    trade_data['tp'] = req_tp
    trade_data['comment'] = f"App {tag}"
    
    res = await manager.execute(mt5_id, "TRADE", trade_data)
    if res.get('status') == 'error': raise HTTPException(400, res['detail'])
    return res

@app.post("/modify")
async def modify_position(item: ModifyRequest):
    u = resolve_user(item.login)
    
    if u['mirror_enabled']:
        item.sl, item.tp = item.tp, item.sl
        
    res = await manager.execute(u['mt5_login'], "MODIFY", item.dict())
    if res.get('status') == 'error': raise HTTPException(400, res['detail'])
    return res

@app.post("/close")
async def close_position(item: CloseRequest):
    u = resolve_user(item.login)
    res = await manager.execute(u['mt5_login'], "CLOSE", item.dict())
    if res.get('status') == 'error': raise HTTPException(400, res['detail'])
    return res

@app.post("/trade_history")
async def get_trade_history(item: HistoryRequest):
    # This endpoint returns the FULL history (Deals/Orders) for the App History Tab.
    # It does NOT use the Cached Profit for calculation, because the User needs to SEE the rows.
    # However, we must filter/virtualize the rows.
    
    u = resolve_user(item.login)
    mt5_id = u['mt5_login']
    
    req = item.dict()
    # Filter by user Start Date if not provided in request
    if not req.get('from_date') and u['virtual_start_date']:
        req['from_date'] = u['virtual_start_date']
    
    res = await manager.execute(mt5_id, "TRADE_HISTORY", req)
    
    if res.get('status') == 'success':
        # Apply Logic to Deals/Positions for Display
        deals = res.get('deals', [])
        positions = res.get('positions', [])
        
        # Helper to virtualize one item
        def virtualize(p):
            # Same logic as WS
            if u['mirror_enabled']:
                if 'type' in p:
                     t = p['type']
                     if t == 'BUY': p['type'] = 'SELL'
                     elif t == 'SELL': p['type'] = 'BUY'
                # Invert Profit
                if 'profit' in p: p['profit'] = -p['profit']
                if 'swap' in p: p['swap'] = -p['swap']
                # Swap SL/TP for display correctness
                if 'sl' in p and 'tp' in p:
                     p['sl'], p['tp'] = p['tp'], p['sl']
                
            if u['multiplier'] > 0 and u['multiplier'] != 1.0:
                if 'volume' in p: p['volume'] = round(p['volume'] / u['multiplier'], 2)
                if 'profit' in p: p['profit'] = round(p['profit'] / u['multiplier'], 2)
                
        for d in deals: virtualize(d)
        for p in positions: virtualize(p)
        
        # Recalculate Summary based on these virtualized items?
        # Ideally yes, but for "Wallet" we use RAM State. 
        # For "History Tab", we trust this list.
        
    if res.get('status') == 'error': raise HTTPException(400, res['detail'])
    return res

@app.get("/history")
async def get_history(login: str, symbol: str, timeframe: str = "M1", count: int = 300):
    u = resolve_user(login)
    
    req = {
        "symbol": symbol,
        "timeframe": timeframe,
        "count": count
    }
    
    # Use worker to fetch history (CopyRates)
    res = await manager.execute(u['mt5_login'], "HISTORY", req, timeout=10)
    if res.get('status') == 'error': raise HTTPException(400, res['detail'])
    return res

# === OPTIMIZED STATE MANAGEMENT ===

# Global RAM State for Real-Time Display
# { app_login : { "balance": X, "equity": Y, "positions": [...] } }
RAM_STATE = {}


async def sync_history_loop():
    print("Started Optimized Sync History Loop")
    # Quotes Loop is now Direct Poll in endpoint
    
    while True:
        try:
            await asyncio.sleep(5) # Check every 5s (Lightweight)
            
            # Optimization: Move blocking DB call to thread if needed
            # For now, keep simple but be aware of blocking
            users = get_all_users()
            for u in users:
                app_login = u['app_login']
                mt5_login = u['mt5_login']
                
                if not manager.is_worker_running(mt5_login): continue
                
                # 1. Get Sync State
                sync = get_sync_state(app_login)
                cached_profit = sync['cached_profit'] if sync else 0.0
                last_time_str = sync['last_sync_time'] if sync else None
                
                # Parse Last Time
                from_date = u['virtual_start_date'] # Default start
                if last_time_str:
                    from_date = last_time_str
                
                # 2. Ask MT5 for NEW deals only
                req = {
                    "login": mt5_login,
                    "group": "DEALS",
                    "from_date": from_date,
                    "to_date": datetime.now().isoformat()
                }
                
                # Short timeout, background
                res = await manager.execute(mt5_login, "TRADE_HISTORY", req, timeout=5)
                
                if res and res.get('status') == 'success':
                    deals = res.get('deals', [])
                    new_profit = 0.0
                    max_time = 0
                    
                    found_new = False
                    
                    for d in deals:
                         # Filter logic could be improved to robustly strictly > last_time
                         d_time = d.get('time', 0)
                         if d_time > max_time: max_time = d_time
                         
                         # Check strict newness if string comparison is loose
                         # Or just trust MT5 ranges.
                         # Apply Multiplier/Mirror Logic to PROFIT
                         
                         raw_profit = d.get('profit', 0) + d.get('swap', 0) + d.get('commission', 0)
                         
                         virtual_profit = raw_profit
                         if u['mirror_enabled']:
                             virtual_profit = virtual_profit * -1
                             
                         if u['multiplier'] > 0:
                             virtual_profit = virtual_profit / u['multiplier']
                             
                         new_profit += virtual_profit
                         
                         # Basic filter: Only count if deal time > previously synced timestamp
                         # (Logic requires numeric timestamp comparison for robustness, but here we assume from_date works)
                         found_new = True

                    # 3. Commit to DB if new
                    if found_new and max_time > 0:
                         # Convert max_time timestamp to iso
                         new_last_sync = datetime.fromtimestamp(max_time + 1).isoformat()
                         # +1 to avoid overlap next time
                         
                         update_sync_state(app_login, new_profit, new_last_sync)
                         cached_profit += new_profit # Update local for RAM step
                
                # 4. Update RAM State (Balance)
                start_bal = u['virtual_start_balance']
                current_balance = start_bal + cached_profit
                
                if app_login not in RAM_STATE: RAM_STATE[app_login] = {}
                RAM_STATE[app_login]['balance'] = round(current_balance, 2)
                RAM_STATE[app_login]['multiplier'] = u['multiplier']
                RAM_STATE[app_login]['mirror'] = u['mirror_enabled']

        except Exception as e:
            print(f"Sync Loop Error: {e}")
            await asyncio.sleep(5)

@app.on_event("startup")
async def startup_event():
    # Load DB
    init_db()
    
    # CRITICAL: Connect Manager to this Event Loop
    manager.set_loop(asyncio.get_running_loop())
    
    # Restore Users & Start Workers
    users = get_all_users()
    for u in users:
        # Start Worker?
        # Maybe we auto-start all? Or wait for manual?
        # For now, let's respect the "previously running" logic or just start all valid
        if u['mt5_path'] and os.path.exists(u['mt5_path']):
             res = manager.start_worker(u['mt5_login'], u['mt5_path'])
             
    # Start Background Loops
    asyncio.create_task(sync_history_loop())
    asyncio.create_task(monitor_positions_task())

async def monitor_positions_task():
    print("Started Background Position Monitor (Auto-Close)")
    while True:
        try:
             users = get_all_users()
             for u in users:
                 mt5_login = u['mt5_login']
                 if not manager.is_worker_running(mt5_login): continue
                 
                 # Fetch Positions for Auto-Close Check
                 # We use a short timeout
                 res = await manager.execute(mt5_login, "POSITIONS", None, timeout=2)
                 
                 if isinstance(res, list):
                     for p in res:
                         # --- AUTO CLOSE LOGIC ---
                         # Ensure we parse config safely
                         try:
                             auto_close_min = float(u.get('auto_close_minutes', 0))
                         except:
                             auto_close_min = 0
                             
                         if auto_close_min > 0 and p.get('time'):
                             open_time = int(p['time'])
                             now_ts = datetime.now().timestamp()
                             duration_min = (now_ts - open_time) / 60.0
                             
                             if duration_min >= auto_close_min:
                                 print(f"AUTO-CLOSE: Closing Ticket {p['ticket']} for {u['app_login']} (Duration: {duration_min:.1f}m > {auto_close_min}m)")
                                 close_req = {"ticket": p['ticket'], "symbol": p['symbol']}
                                 await manager.execute(mt5_login, "CLOSE", close_req, timeout=5)
                                 
        except Exception as e:
            print(f"Monitor Loop Error: {e}")
            
        await asyncio.sleep(2) # Check every 2 seconds

@app.websocket("/ws/positions")
async def websocket_positions(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            # 1. Iterate RAM State for Active Users
            payload = {}
            
            users = get_all_users()
            for u in users:
                app_login = u['app_login']
                mt5_login = u['mt5_login']
                
                # Base from RAM (DB Sync)
                base_data = RAM_STATE.get(app_login, {})
                virtual_balance = base_data.get('balance', u['virtual_start_balance'])
                
                # Fetch Real-Time Floating
                if manager.is_worker_running(mt5_login):
                    pos_res = await manager.execute(mt5_login, "POSITIONS", None, timeout=1)
                    acc_res = await manager.execute(mt5_login, "ACCOUNT_INFO", None, timeout=1)
                    
                    floating = 0.0
                    virtual_positions = []
                    
                    if isinstance(pos_res, list):
                        for p in pos_res:
                            # Auto-Close is now handled in background task
                            
                            # Calc Virtual Profit per position
                            raw_p = p.get('profit', 0) + p.get('swap', 0) + p.get('commission', 0)
                            v_p = raw_p
                            if u['mirror_enabled']: v_p = -1 * raw_p
                            if u['multiplier'] > 0: v_p = v_p / u['multiplier']
                            
                            floating += v_p
                            
                            # Modify p for display
                            p['profit'] = round(v_p, 2)
                            # Swap Side string
                            if u['mirror_enabled']:
                                p['type'] = 'SELL' if p['type'] == 'BUY' else 'BUY'
                                # Swap SL/TP logic for visual consistency
                                _sl = p.get('sl', 0.0)
                                _tp = p.get('tp', 0.0)
                                p['sl'] = _tp
                                p['tp'] = _sl
                            if u['multiplier'] > 0:
                                p['volume'] = round(p['volume'] / u['multiplier'], 2)
                                
                            virtual_positions.append(p)
                    
                    equity = virtual_balance + floating
                    
                    # Margin Calculation
                    real_margin = acc_res.get('margin', 0) if isinstance(acc_res, dict) else 0
                    v_margin = real_margin
                    if u['multiplier'] > 0: v_margin = v_margin / u['multiplier']
                    
                    free_margin = equity - v_margin
                    
                    payload[app_login] = {
                        "account": {
                            "login": app_login,
                            "balance": round(virtual_balance, 2),
                            "equity": round(equity, 2),
                            "margin": round(v_margin, 2),
                            "margin_free": round(free_margin, 2),
                            "profit": round(floating, 2)
                        },
                        "positions": virtual_positions
                    }
            
            if payload:
                await websocket.send_json(payload)
            
            await asyncio.sleep(1) # 1 FPS Update
            
    except WebSocketDisconnect:
        print("WS Client Disconnected (Positions)")
    except Exception as e:
        print(f"WS Positions Error: {e}")
        traceback.print_exc()

@app.websocket("/ws/quotes")
async def websocket_quotes(websocket: WebSocket):
    await websocket.accept()
    print("WS Client Connected (Direct Poll Mode)")
    
    WATCHLIST = ["EURUSD", "GBPUSD", "USDJPY", "XAUUSD", "BTCUSD"]
    
    try:
        while True:
            # 1. Choose a source (any running worker)
            active_ids = list(manager.workers.keys())
            if not active_ids:
                await asyncio.sleep(1)
                continue
                
            feed_id = active_ids[0]
            
            # 2. Fetch Ticks directly
            # print(f"DEBUG: Direct fetching ticks from {feed_id}...")
            res = await manager.execute(feed_id, "TICKS", WATCHLIST, timeout=1)
            
            ticks = {}
            # Update: _handle_ticks returns the dict directly, not nested in 'result'
            if res and isinstance(res, dict) and 'status' not in res:
                 ticks = res
                 # print(f"DEBUG: Ticks fetched: {len(ticks)} symbols")
            elif res and isinstance(res, dict) and res.get('status') == 'error':
                 print(f"DEBUG: Worker Error: {res}")
            else:
                 # Fallback if structure changes
                 ticks = res.get('result', {}) if isinstance(res, dict) else {}
                
            # 3. Stream each tick to this client
            sent_count = 0
            for symbol, data in ticks.items():
                if data['time'] == 0: continue
                
                payload = {
                    "symbol": symbol,
                    "bid": data['bid'],
                    "ask": data['ask'],
                    "time": data['time'],
                    "server": feed_id 
                }
                await websocket.send_json(payload)
                sent_count += 1
                
            # print(f"DEBUG: Sent {sent_count} quotes to client")
            
            await asyncio.sleep(0.5) # 2 FPS
            
    except WebSocketDisconnect:
        print("WS Client Disconnected (Quotes)")
    except Exception as e:
        print(f"WS Quotes Error: {e}")
        # traceback.print_exc()

# === GUI THREAD ===
class ServerThread(QThread):
    def run(self):
        config = uvicorn.Config(app, host="0.0.0.0", port=8000, log_level="error")
        server = uvicorn.Server(config)
        server.run()

class BackendGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("MirrorTrade Admin (SQLite + Async)")
        self.resize(1000, 600)
        
        self.server_thread = ServerThread()
        self.server_thread.start()
        
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        
        self.tabs = QTabWidget()
        self.tab_users = QWidget()
        self.setup_users_tab()
        self.tabs.addTab(self.tab_users, "User Management")
        
        self.tab_add = QWidget()
        self.setup_add_tab()
        self.tabs.addTab(self.tab_add, "Add/Edit User")
        
        layout.addWidget(self.tabs)
        
        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh_table)
        self.timer.start(2000)

    def setup_users_tab(self):
        layout = QVBoxLayout(self.tab_users)
        self.table = QTableWidget()
        self.table.setColumnCount(6)
        self.table.setHorizontalHeaderLabels(["App Login", "MT5 ID", "Status", "Mirror", "Mult", "Virt Balance"])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self.context_menu)

        
        btn_layout = QHBoxLayout()
        btn_refresh = QPushButton("Refresh List")
        btn_refresh.clicked.connect(self.refresh_table)
        btn_add = QPushButton("Add User")
        btn_add.clicked.connect(self.goto_add)

        
        btn_layout.addWidget(btn_refresh)
        btn_layout.addWidget(btn_add)
        
        layout.addWidget(self.table)
        layout.addLayout(btn_layout)

    def refresh_table(self):
        users = get_all_users()
        self.table.setRowCount(0)
        for r, u in enumerate(users):
            self.table.insertRow(r)
            self.table.setItem(r, 0, QTableWidgetItem(str(u['app_login'])))
            self.table.setItem(r, 1, QTableWidgetItem(str(u['mt5_login'])))
            
            is_run = manager.is_worker_running(u['mt5_login'])
            status = "Online" if is_run else "Offline"
            self.table.setItem(r, 2, QTableWidgetItem(status))
            
            self.table.setItem(r, 3, QTableWidgetItem("YES" if u['mirror_enabled'] else "NO"))
            self.table.setItem(r, 4, QTableWidgetItem(str(u['multiplier'])))
            
            # Show cached balance from RAM if available, else DB
            bal = u['virtual_start_balance']
            if u['app_login'] in RAM_STATE:
                bal = RAM_STATE[u['app_login']].get('balance', bal)
            self.table.setItem(r, 5, QTableWidgetItem(f"${bal:.2f}"))

    def context_menu(self, pos):
        item = self.table.itemAt(pos)
        if not item: return
        
        row = item.row()
        app_login = self.table.item(row, 0).text()
        
        menu = QMenu()
        act_edit = QAction("Edit User", self)
        act_edit.triggered.connect(lambda: self.load_user_edit(app_login))
        menu.addAction(act_edit)
        
        act_del = QAction("Delete User", self)
        act_del.triggered.connect(lambda: self.delete_user_action(app_login))
        menu.addAction(act_del)
        
        menu.exec(self.table.viewport().mapToGlobal(pos))

    def load_user_edit(self, app_login):
        u = get_user_by_app_login(app_login)
        if not u: return
        
        self.inp_app_login.setText(u['app_login'])
        self.inp_app_login.setReadOnly(True) # Cannot change ID
        self.inp_app_pass.setText(u['app_password'])
        self.inp_app_server.setText(u['app_server'])
        
        self.inp_mt5_login.setText(str(u['mt5_login']))
        self.inp_mt5_pass.setText(u['mt5_password'])
        self.inp_mt5_server.setText(u['mt5_server'])
        self.inp_mt5_path.setText(u['mt5_path'])
        
        self.chk_mirror.setChecked(bool(u['mirror_enabled']))
        self.inp_mult.setValue(float(u['multiplier']))
        self.inp_start_bal.setValue(float(u['virtual_start_balance']))
        self.inp_autoclose.setValue(int(u['auto_close_minutes']))
        
        self.tabs.setCurrentIndex(1)

    def delete_user_action(self, app_login):
        ret = QMessageBox.question(self, "Confirm", f"Delete user {app_login}?")
        if ret == QMessageBox.StandardButton.Yes:
            # Create helper for stopping worker if running
            u = get_user_by_app_login(app_login)
            if u:
                manager.stop_worker(u['mt5_login'])
            delete_user(app_login)
            self.refresh_table()


    def setup_add_tab(self):
        layout = QFormLayout(self.tab_add)
        
        self.inp_app_login = QLineEdit()
        self.inp_app_pass = QLineEdit()
        self.inp_app_server = QLineEdit("AxTrade VIP")
        
        self.inp_mt5_login = QLineEdit()
        self.inp_mt5_pass = QLineEdit()
        self.inp_mt5_server = QLineEdit()
        self.inp_mt5_path = QLineEdit()
        btn_browse = QPushButton("Browse")
        btn_browse.clicked.connect(self.browse_path)
        
        path_box = QHBoxLayout()
        path_box.addWidget(self.inp_mt5_path)
        path_box.addWidget(btn_browse)
        
        self.chk_mirror = QCheckBox("Enable Mirror")
        self.inp_mult = QDoubleSpinBox()
        self.inp_mult.setValue(1.0)
        
        self.inp_start_bal = QDoubleSpinBox()
        self.inp_start_bal.setRange(0, 1000000)
        self.inp_start_bal.setValue(1000)

        self.inp_autoclose = QSpinBox()
        self.inp_autoclose.setRange(0, 10000)
        self.inp_autoclose.setSuffix(" min")
        self.inp_autoclose.setValue(0)

        
        layout.addRow("App Login:", self.inp_app_login)
        layout.addRow("App Password:", self.inp_app_pass)
        layout.addRow("App Server Name:", self.inp_app_server)
        layout.addRow(QLabel("--- MT5 Connection ---"))
        layout.addRow("MT5 Login ID:", self.inp_mt5_login)
        layout.addRow("MT5 Password:", self.inp_mt5_pass)
        layout.addRow("MT5 Server:", self.inp_mt5_server)
        layout.addRow("Terminal Path:", path_box)
        layout.addRow(QLabel("--- Risk Settings ---"))
        layout.addRow(self.chk_mirror)
        layout.addRow("Multiplier:", self.inp_mult)
        layout.addRow("Start Balance ($):", self.inp_start_bal)
        layout.addRow("Auto Close (min):", self.inp_autoclose)

        
        btn_save = QPushButton("Save User")
        btn_save.clicked.connect(self.save_user)
        layout.addRow(btn_save)

    def browse_path(self):
        f, _ = QFileDialog.getOpenFileName(self, "Select terminal64.exe")
        if f: self.inp_mt5_path.setText(f)

    def save_user(self):
        try:
            data = {

                "app_login": self.inp_app_login.text(),

                "app_password": self.inp_app_pass.text(),
                "app_server": self.inp_app_server.text(),
                "mt5_login": int(self.inp_mt5_login.text()),
                "mt5_password": self.inp_mt5_pass.text(),
                "mt5_server": self.inp_mt5_server.text(),
                "mt5_path": self.inp_mt5_path.text(),
                "mirror_enabled": self.chk_mirror.isChecked(),
                "multiplier": self.inp_mult.value(),
                "virtual_start_balance": self.inp_start_bal.value(),
                "virtual_start_date": datetime.now().isoformat(),
                "auto_close_minutes": self.inp_autoclose.value()

            }
            if create_or_update_user(data):
                # RESET HISTORY STATE on Edit
                # This ensures Balance = Start Balance (No ghost profit from past)
                reset_sync_state(data['app_login'])
                if data['app_login'] in RAM_STATE:
                    del RAM_STATE[data['app_login']]
                    
                QMessageBox.information(self, "Success", "User Saved! (History Reset)")
                self.tabs.setCurrentIndex(0)
                # Auto start
                manager.start_worker(data['mt5_login'], data['mt5_path'])
            else:
                QMessageBox.warning(self, "Error", "Failed to save DB")
        except Exception as e:
            QMessageBox.warning(self, "Error", str(e))

    def goto_add(self):
        self.inp_app_login.clear()
        self.inp_app_login.setReadOnly(False)
        self.inp_app_pass.clear()
        self.inp_mt5_login.clear()
        self.inp_mt5_pass.clear()
        self.tabs.setCurrentIndex(1)
        
if __name__ == "__main__":

    multiprocessing.freeze_support()
    app_qt = QApplication(sys.argv)
    win = BackendGUI()
    win.show()
    sys.exit(app_qt.exec())
