import sqlite3
import os
import json
from datetime import datetime
from typing import Optional, Dict, List

DB_FILE = os.path.join(os.path.dirname(__file__), "mirror_trade.db")

def get_db_connection():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db_connection()
    c = conn.cursor()
    
    # 1. Users Table (Configuration & Mapping)
    c.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_login TEXT UNIQUE NOT NULL,
            app_password TEXT NOT NULL,
            app_server TEXT DEFAULT 'MirrorTrade Server',
            
            mt5_login INTEGER NOT NULL,
            mt5_password TEXT NOT NULL,
            mt5_server TEXT NOT NULL,
            mt5_path TEXT NOT NULL,
            
            note TEXT,
            is_active INTEGER DEFAULT 1,
            
            mirror_enabled INTEGER DEFAULT 0,
            multiplier REAL DEFAULT 1.0,
            
            virtual_start_balance REAL DEFAULT 0.0,
            virtual_start_date TEXT,
            auto_close_minutes INTEGER DEFAULT 0,
            
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    # 2. Account Sync Table (Persisted State of Closed P/L)
    c.execute('''
        CREATE TABLE IF NOT EXISTS account_sync (
            app_login TEXT PRIMARY KEY,
            mt5_login INTEGER,
            cached_profit REAL DEFAULT 0.0,
            last_sync_time TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (app_login) REFERENCES users(app_login)
        )
    ''')
    
    conn.commit()
    conn.close()
    print(f"Database initialized at {DB_FILE}")

# === User Management ===

def create_or_update_user(data: Dict):
    conn = get_db_connection()
    c = conn.cursor()
    
    try:
        # Check if exists
        c.execute("SELECT id FROM users WHERE app_login = ?", (data['app_login'],))
        exists = c.fetchone()
        
        if exists:
            # Update
            query = '''
                UPDATE users SET 
                    app_password = ?, app_server = ?,
                    mt5_login = ?, mt5_password = ?, mt5_server = ?, mt5_path = ?,
                    note = ?, is_active = ?,
                    mirror_enabled = ?, multiplier = ?,
                    virtual_start_balance = ?, virtual_start_date = ?, auto_close_minutes = ?
                WHERE app_login = ?
            '''
            params = (
                data['app_password'], data.get('app_server', 'MirrorTrade Server'),
                data['mt5_login'], data['mt5_password'], data['mt5_server'], data['mt5_path'],
                data.get('note', ''), data.get('is_active', 1),
                1 if data.get('mirror_enabled') else 0, data.get('multiplier', 1.0),
                data.get('virtual_start_balance', 0.0), data.get('virtual_start_date', ''), data.get('auto_close_minutes', 0),
                data['app_login']
            )
            c.execute(query, params)
        else:
            # Insert
            query = '''
                INSERT INTO users (
                    app_login, app_password, app_server,
                    mt5_login, mt5_password, mt5_server, mt5_path,
                    note, is_active,
                    mirror_enabled, multiplier,
                    virtual_start_balance, virtual_start_date, auto_close_minutes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            '''
            params = (
                data['app_login'], data['app_password'], data.get('app_server', 'MirrorTrade Server'),
                data['mt5_login'], data['mt5_password'], data['mt5_server'], data['mt5_path'],
                data.get('note', ''), data.get('is_active', 1),
                1 if data.get('mirror_enabled') else 0, data.get('multiplier', 1.0),
                data.get('virtual_start_balance', 0.0), data.get('virtual_start_date', ''), data.get('auto_close_minutes', 0)
            )
            c.execute(query, params)
        
        # Ensure Sync Record Exists
        c.execute("INSERT OR IGNORE INTO account_sync (app_login, mt5_login) VALUES (?, ?)", 
                  (data['app_login'], data['mt5_login']))
        
        conn.commit()
        return True
    except Exception as e:
        print(f"DB Error create_or_update_user: {e}")
        return False
    finally:
        conn.close()

def get_user_by_app_login(app_login: str):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT * FROM users WHERE app_login = ?", (app_login,))
    row = c.fetchone()
    conn.close()
    if row: return dict(row)
    return None

def get_all_users():
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT * FROM users ORDER BY created_at DESC")
    rows = c.fetchall()
    conn.close()
    return [dict(row) for row in rows]

def delete_user(app_login: str):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("DELETE FROM account_sync WHERE app_login = ?", (app_login,))
    c.execute("DELETE FROM users WHERE app_login = ?", (app_login,))
    conn.commit()
    conn.close()

# === Sync State Management ===

def get_sync_state(app_login: str):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT * FROM account_sync WHERE app_login = ?", (app_login,))
    row = c.fetchone()
    conn.close()
    if row: return dict(row)
    return None

def update_sync_state(app_login: str, added_profit: float, last_sync_time: str):
    conn = get_db_connection()
    c = conn.cursor()
    
    # Atomic Update: Increment Profit
    c.execute('''
        UPDATE account_sync 
        SET cached_profit = cached_profit + ?, 
            last_sync_time = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE app_login = ?
    ''', (added_profit, last_sync_time, app_login))
    
    conn.commit()
    conn.close()

def reset_sync_state(app_login: str):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("UPDATE account_sync SET cached_profit = 0, last_sync_time = NULL WHERE app_login = ?", (app_login,))
    conn.commit()
    conn.close()

# Initialize on Import if not exists
if not os.path.exists(DB_FILE):
    init_db()
