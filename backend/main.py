import time
import os
from dotenv import load_dotenv
from datetime import datetime
from fastapi import FastAPI, HTTPException, Request, WebSocket, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
import json
import asyncio
import traceback
import multiprocessing
import queue
import uuid
from backend.mt5_worker import MT5Worker  # Ensure this import works relative to root or use relative import

load_dotenv()

app = FastAPI(title="MirrorTradeMT5 Backend (Multi-Worker)", version="3.1")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# === CONFIG ===
CONFIG_FILE = os.path.join(os.path.dirname(__file__), "config.json")

def load_config():
    default_path = [os.getenv("MT5_PATH", r"C:\Program Files\MetaTrader 5\terminal64.exe")]
    if not os.path.exists(CONFIG_FILE):
        print(f"Config file {CONFIG_FILE} not found, using env or default.")
        return default_path, {}
    
    try:
        with open(CONFIG_FILE, "r") as f:
            data = json.load(f)
            paths = data.get("terminal_paths", [])
            
            sanitized_paths = []
            for p in paths:
                # Basic check: if strictly directory provided, add exe
                # Or just check extension
                if not p.lower().endswith(".exe"):
                    p = os.path.join(p, "terminal64.exe")
                sanitized_paths.append(p)

            if not sanitized_paths:
                print("No paths in config, using default.")
                return default_path, {}
            
            server_map = data.get("server_map", {})
            return sanitized_paths, server_map
    except Exception as e:
        print(f"Error reading config: {e}")
        return default_path, {}

TERMINAL_PATHS, SERVER_MAP = load_config() 

# === WORKER MANAGER ===
class WorkerManager:
    def __init__(self):
        self.workers = []
        self.queues = [] # List of tuples (cmd_queue, res_queue)
        self.user_map = {} # user_login -> worker_index
        self.lock = asyncio.Lock()

    def start_workers(self):
        print(f"Starting {len(TERMINAL_PATHS)} Workers...")
        for i, path in enumerate(TERMINAL_PATHS):
            cmd_q = multiprocessing.Queue()
            res_q = multiprocessing.Queue()
            
            w = MT5Worker(worker_id=i, terminal_path=path, command_queue=cmd_q, result_queue=res_q)
            w.start()
            
            self.workers.append(w)
            self.queues.append((cmd_q, res_q))
        print("Workers Started.")

    def stop_workers(self):
        for q, _ in self.queues:
            q.put({"type": "STOP"})
        for w in self.workers:
            w.join()

    def get_worker_index(self, login: int = None):
        # Strategy: 
        # 1. If login is assigned, return assigned worker.
        # 2. If not, assign to worker with least users (Load Balancing).
        # 3. For Public Data (Quotes), use Worker 0.
        
        if login is None:
            return 0
            
        if login in self.user_map:
            return self.user_map[login]
            
        # Assign new (Simple Round Robin or Random)
        # For simplicity, just use modulo or first available
        assigned_worker = login % len(self.workers)
        self.user_map[login] = assigned_worker
        print(f"Assigned User {login} to Worker {assigned_worker}")
        return assigned_worker

    async def execute(self, worker_idx, command_type, data=None, timeout=15): # Increased timeout
        if worker_idx >= len(self.queues):
            return {"status": "error", "detail": "Worker not found"}

        cmd_q, res_q = self.queues[worker_idx]
        request_id = str(uuid.uuid4())
        
        cmd = {"type": command_type, "id": request_id, "data": data}
        
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self._blocking_execute, cmd_q, res_q, request_id, cmd, timeout)

    def _blocking_execute(self, cmd_q, res_q, req_id, cmd, timeout):
        try:
            cmd_q.put(cmd)
            
            start = time.time()
            while time.time() - start < timeout:
                try:
                    res = res_q.get(timeout=0.5)
                    
                    # Safety check for messages without ID (e.g. Init errors)
                    if not isinstance(res, dict) or 'id' not in res:
                        if res.get('status') == 'error':
                             print(f"WORKER ERROR: {res.get('detail')}")
                        continue

                    if res['id'] == req_id:
                        return res['result']
                    else:
                        res_q.put(res) 
                except queue.Empty:
                    continue
            return {"status": "error", "detail": "Request timed out (Backend)"}
        except Exception as e:
            return {"status": "error", "detail": str(e)}

manager = WorkerManager()

@app.on_event("startup")
async def startup_event():
    manager.start_workers()

@app.on_event("shutdown")
async def shutdown_event():
    manager.stop_workers()

@app.get("/")
def read_root():
    return {"status": "running", "mode": "multi-worker", "workers": len(manager.workers)}

# === MODELS ===
class LoginRequest(BaseModel):
    login: int
    password: str
    server: str

class TradeRequest(BaseModel):
    action: str 
    symbol: str
    volume: float
    price: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    order_mode: str = "MARKET"
    # Helper to route:
    login: int = 0  # Added field to route to correct worker

class ModifyRequest(BaseModel):
    ticket: int
    symbol: str
    sl: float
    tp: float
    login: int = 0

class CloseRequest(BaseModel):
    ticket: int
    symbol: str
    login: int = 0

class HistoryRequest(BaseModel):
    login: int = 0
    from_date: Optional[str] = None
    to_date: Optional[str] = None
    group: str = "DEALS" # DEALS or ORDERS

# === ENDPOINTS ===

@app.post("/login")
async def login_mt5(item: LoginRequest):
    # Determine worker
    worker_idx = manager.get_worker_index(item.login)
    
    # Handle Server Alias
    real_server = SERVER_MAP.get(item.server, item.server)
    if real_server != item.server:
        print(f"Server Alias: {item.server} -> {real_server}")
    
    login_data = item.dict()
    login_data['server'] = real_server
    
    res = await manager.execute(worker_idx, "LOGIN", login_data)
    
    if res['status'] == 'error':
        raise HTTPException(status_code=400, detail=res['detail'])
        
    return res

@app.post("/trade")
async def place_trade(item: TradeRequest):
    worker_idx = manager.get_worker_index(item.login) # Need login to identify context
    # If login missing, maybe use default? 
    # For now assume client sends it or we default to 0
    res = await manager.execute(worker_idx, "TRADE", item.dict())
    if res['status'] == 'error': throw_error(res)
    return res

@app.post("/modify")
async def modify_position(item: ModifyRequest):
    worker_idx = manager.get_worker_index(item.login)
    res = await manager.execute(worker_idx, "MODIFY", item.dict())
    if res['status'] == 'error': throw_error(res)
    return res

@app.post("/close")
async def close_position(item: CloseRequest):
    worker_idx = manager.get_worker_index(item.login)
    res = await manager.execute(worker_idx, "CLOSE", item.dict())
    if res['status'] == 'error': throw_error(res)
    return res

@app.get("/history")
async def get_history(
    symbol: str = Query(...), 
    timeframe: str = Query("M1"), 
    count: int = Query(300),
    login: int = Query(0)
):
    # Construct dict to match internal command structure
    item = {
        "symbol": symbol,
        "timeframe": timeframe,
        "count": count,
        "login": login
    }
    
    worker_idx = manager.get_worker_index(login)
    res = await manager.execute(worker_idx, "HISTORY", item)
    return res

@app.post("/trade_history")
async def get_trade_history(item: HistoryRequest):
    worker_idx = manager.get_worker_index(item.login)
    res = await manager.execute(worker_idx, "TRADE_HISTORY", item.dict())
    if res['status'] == 'error': throw_error(res)
    return res

def throw_error(res):
    raise HTTPException(status_code=400, detail=res.get('detail', 'Unknown error'))

# === WEBSOCKETS ===
# NOTE: Client app might need to send a "login" or "token" frame first to identify user.
# For POC, we assume single worker (Worker 0) for streaming Quotes.

@app.websocket("/ws/quotes")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    worker_idx = 0 # Default Quote Provider
    try:
        symbols_to_watch = ["EURUSD", "XAUUSD", "BTCUSD"] # Simplified list
        
        while True:
            res = await manager.execute(worker_idx, "TICKS", symbols_to_watch, timeout=1)
            if res and isinstance(res, dict) and "status" not in res: # Valid data
                for s, data in res.items():
                    # Format as existing app expects
                    payload = {
                        "symbol": s,
                        "mt5_symbol": s,
                        "bid": data['bid'],
                        "ask": data['ask'],
                        "time": data['time'],
                         "server_time": datetime.fromtimestamp(data['time']).strftime("%H:%M:%S")
                    }
                    await websocket.send_json(payload)
            
            await asyncio.sleep(0.5) # Throttle 
    except Exception as e:
        print(f"WS Error: {e}")

@app.websocket("/ws/positions")
async def websocket_positions(websocket: WebSocket):
    await websocket.accept()
    # Problem: Which user's positions?
    # Websocket protocol usually involves: Client connects -> Sends Auth -> Server Streams
    # For POC, let's just peek Worker 0 positions
    worker_idx = 0 
    try:
        while True:
             # Need a command POSITIONS in Worker
             data = await manager.execute(worker_idx, "POSITIONS", None)
             acc = await manager.execute(worker_idx, "ACCOUNT_INFO", None)
             
             if isinstance(data, list):
                 payload = {"account": acc, "positions": data}
                 await websocket.send_json(payload)
             await asyncio.sleep(1)
    except Exception as e:
        print(e)
