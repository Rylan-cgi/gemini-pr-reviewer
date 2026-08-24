#!/usr/bin/env python3
import os
import json
import time
from datetime import datetime

# Path definitions
STATE_FILE = "/home/rylanevans/.gemini/tmp/ilcr-pr-reviews.json"
ACTIVE_STATE_FILE = "/home/rylanevans/.gemini/tmp/ilcr-pr-active-state.json"

# ANSI color codes
CLR_HEADER = "\033[95m"
CLR_CYAN = "\033[96m"
CLR_BLUE = "\033[94m"
CLR_GREEN = "\033[92m"
CLR_YELLOW = "\033[93m"
CLR_RED = "\033[91m"
CLR_BOLD = "\033[1m"
CLR_RESET = "\033[0m"

# Track terminal size to handle resizes cleanly
LAST_COLS = 0

def reset_cursor():
    # Move terminal cursor back to top-left (row 1, col 1) without clearing screen.
    # This prevents the scrollbar from jumping and eliminates terminal text flickering.
    print("\033[H", end="")

def load_json(file_path):
    if not os.path.exists(file_path):
        return {}
    try:
        with open(file_path, 'r') as f:
            return json.load(f)
    except Exception:
        return {}

def draw_box_line(text, width, align="left", color=""):
    inner_width = width - 4
    
    # Safety truncation: if text exceeds the current box width, truncate with '...'
    # to completely prevent line-wrapping or layout shifts.
    if len(text) > inner_width:
        text = text[:inner_width - 3] + "..."
        
    if align == "center":
        padding = (inner_width - len(text)) // 2
        line = " " * padding + text + " " * (inner_width - len(text) - padding)
    else:
        line = " " + text + " " * (inner_width - len(text) - 1)
        
    # \033[K clears from cursor position to the end of the line.
    return f"│ {color}{line}{CLR_RESET} │\033[K"

def format_status(status):
    if status == "approved":
        return f"{CLR_GREEN}APPROVED{CLR_RESET}"
    elif status == "changes_requested":
        return f"{CLR_RED}CHANGES REQ{CLR_RESET}"
    elif status == "skipped":
        return f"{CLR_YELLOW}SKIPPED{CLR_RESET}"
    return f"{CLR_BLUE}{status.upper()}{CLR_RESET}"

def render_dashboard():
    global LAST_COLS
    
    # 1. Dynamically detect the active terminal dimensions
    try:
        columns, lines = os.get_terminal_size()
    except Exception:
        columns = 80
        lines = 24
        
    # Cap the box width at 80 characters for optimal aesthetics on wide monitors,
    # but scale it down smoothly to fit narrow splits exactly.
    width = min(80, columns - 1)
    if width < 30:
        width = 30 # absolute floor size for safety
        
    # If the user resizes or splits their terminal, clear the screen once
    # to wipe out margin residues of previous dimensions.
    if columns != LAST_COLS:
        os.system('clear')
        LAST_COLS = columns
        
    # Keep terminal cursor at top-left
    reset_cursor()
    
    # Load JSON files
    active = load_json(ACTIVE_STATE_FILE)
    reviews = load_json(STATE_FILE)

    daemon_status = active.get("status", "offline")
    current_pr = active.get("current_pr", "none")
    repo = active.get("active_repo", "unknown/repo")
    updated_at = active.get("updated_at", "never")
    queue = active.get("queue", [])

    # Clear-to-end of line is appended to borders to maintain consistent erasure
    border_top = "┌" + "─" * (width - 2) + "┐\033[K"
    border_bottom = "└" + "─" * (width - 2) + "┘\033[K"
    border_divider = "├" + "─" * (width - 2) + "┤\033[K"

    # Header Panel
    print(border_top)
    print(draw_box_line("🤖 GEMINI AUTOMATED PR REVIEW AGENT", width, "center", CLR_HEADER + CLR_BOLD))
    print(draw_box_line(f"Active Repository: {repo}", width, "center", CLR_CYAN))
    print(border_divider)

    # Daemon Status Block
    print(draw_box_line("[ ACTIVE DAEMON STATUS ]", width, "left", CLR_CYAN + CLR_BOLD))
    
    status_str = "Offline"
    status_color = CLR_RED
    if daemon_status == "sleeping":
        status_str = "💤 Idle (Sleeping between scan cycles)"
        status_color = CLR_YELLOW
    elif daemon_status == "scanning":
        status_str = "🔍 Scanning repository open PRs..."
        status_color = CLR_CYAN
    elif daemon_status == "reviewing":
        status_str = f"🤖 Reviewing Pull Request #{current_pr}"
        status_color = CLR_BLUE + CLR_BOLD

    print(draw_box_line(f"State:       {status_str}", width, "left", status_color))
    print(draw_box_line(f"Last Poll:   {updated_at}", width, "left", CLR_RESET))
    print(border_divider)

    # Active Scanning Queue
    print(draw_box_line("[ ACTIVE SCAN QUEUE ]", width, "left", CLR_CYAN + CLR_BOLD))
    if not queue:
        print(draw_box_line("   (Queue is currently empty - all PRs up to date)", width, "left", CLR_YELLOW))
    else:
        for idx, item in enumerate(queue):
            pr_num = item.get("number")
            author = item.get("author")
            sha = item.get("sha", "")[:7]
            
            # Highlight the currently active PR
            if str(pr_num) == str(current_pr) and daemon_status == "reviewing":
                item_str = f"👉 [{idx+1}] PR #{pr_num} by @{author} (SHA: {sha}) [ACTIVE]"
                item_color = CLR_BLUE + CLR_BOLD
            else:
                item_str = f"   [{idx+1}] PR #{pr_num} by @{author} (SHA: {sha}) [QUEUED]"
                item_color = CLR_RESET
            print(draw_box_line(item_str, width, "left", item_color))
    print(border_divider)

    # Reviewed History Box
    print(draw_box_line("[ RECENTLY REVIEWED DATABASE CACHE ]", width, "left", CLR_CYAN + CLR_BOLD))
    if not reviews:
        print(draw_box_line("   (No PRs recorded in local state database yet)", width, "left", CLR_YELLOW))
    else:
        # Table Header
        print(draw_box_line("   PR #    Status             Commit HEAD SHA", width, "left", CLR_BOLD))
        print(draw_box_line("   " + "─" * 60, width, "left", CLR_RESET))
        
        # Sort keys descending
        for pr_num in sorted(reviews.keys(), key=lambda x: int(x), reverse=True):
            entry = reviews[pr_num]
            sha = entry.get("last_reviewed_sha", "unknown")[:8]
            status = entry.get("status", "unknown")
            
            # Format row
            row_str = f"   #{pr_num:<6}  {format_status(status):<25}  {sha}"
            print(draw_box_line(row_str, width, "left"))
            
    print(border_bottom)
    print(f"\n{CLR_CYAN}Press Ctrl+C to exit dashboard view.{CLR_RESET}\033[K")

def main():
    try:
        # Full clear once at initial startup to clean screen
        os.system('clear')
        # Hide standard terminal cursor
        print("\033[?25l", end="")
        while True:
            render_dashboard()
            time.sleep(0.5) # Refresh dynamically every 0.5s for real-time responsiveness
    except KeyboardInterrupt:
        # Restore standard terminal cursor on exit
        print("\033[?25h", end="")
        print("\n👋 Dashboard closed.")

if __name__ == "__main__":
    main()
