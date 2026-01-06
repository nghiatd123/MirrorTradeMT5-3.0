import MetaTrader5 as mt5
import sys

path = r"E:\Python_project\MirrorTradeMT5\MT5_TK2\terminal64.exe"

print(f"Testing Initialization for: {path}")
print("Attempting initialize...", flush=True)

try:
    if not mt5.initialize(path=path):
        print(f"Initialize Failed: {mt5.last_error()}")
    else:
        print("Initialize SUCCESS!")
        print(mt5.terminal_info())
        mt5.shutdown()
except Exception as e:
    print(f"Exception: {e}")

input("Press Enter to exit...")
