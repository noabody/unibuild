#!/usr/bin/env python3
import tkinter as tk
from tkinter import messagebox
import re

def to_hours_minutes(hours):
    sign = "-" if hours < 0 else ""
    abs_hours = abs(hours)
    h = int(abs_hours)
    m = round((abs_hours - h) * 60)
    return f"{sign}{h}h {m:02d}m"

def calculate():
    raw = text_list.get("1.0", tk.END)
    try:
        target = float(entry_target.get())
    except ValueError:
        messagebox.showerror("Error", "Enter a numeric target (e.g., 7.5).")
        return

    lines = raw.split("\n")
    values = []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        # Accept pure numeric values (handles commas or decimals)
        if re.match(r"^-?(\d+([.,]\d*)?|[.,]\d+)$", line):
            values.append(float(line.replace(",", ".")))

    if not values:
        messagebox.showerror("Error", "No valid numeric values found.")
        return

    total = sum(values)
    diff = target - total

    label_total_val.config(text=f"{total:.2f} hours ({to_hours_minutes(total)})")
    label_diff_val.config(text=f"{diff:.2f} hours ({to_hours_minutes(diff)})")

# GUI Setup
root = tk.Tk()
root.title("Time Calculator")
root.geometry("300x450")

# Setup outer padding margins using standard configuration
root.config(padx=15, pady=15)

# Widgets Layout
tk.Label(root, text="Enter fractional hours (one per line):", font=("Arial", 10, "bold")).pack(anchor="w", pady=(0,5))
text_list = tk.Text(root, height=10, font=("Courier", 11))
text_list.pack(fill="both", expand=True, pady=(0,10))

tk.Label(root, text="Target hours:", font=("Arial", 10, "bold")).pack(anchor="w")
entry_target = tk.Entry(root, font=("Arial", 11))
entry_target.insert(0, "7.5")
entry_target.pack(fill="x", pady=(0,15))

btn_calc = tk.Button(root, text="Calculate", font=("Arial", 11, "bold"), bg="#0078d4", fg="white", command=calculate)
btn_calc.pack(fill="x", pady=(0,15))

# Fixed: Standard LabelFrame uses padx/pady, not 'padding'
frame_results = tk.LabelFrame(root, text=" Results ", font=("Arial", 10, "bold"), padx=10, pady=10)
frame_results.pack(fill="x")

tk.Label(frame_results, text="Total:", font=("Arial", 10)).grid(row=0, column=0, sticky="w")
label_total_val = tk.Label(frame_results, text="–", font=("Arial", 10, "bold"))
label_total_val.grid(row=0, column=1, sticky="w", padx=10)

tk.Label(frame_results, text="Difference:", font=("Arial", 10)).grid(row=1, column=0, sticky="w", pady=(5,0))
label_diff_val = tk.Label(frame_results, text="–", font=("Arial", 10, "bold"), fg="#d83b01")
label_diff_val.grid(row=1, column=1, sticky="w", padx=10, pady=(5,0))

root.mainloop()
