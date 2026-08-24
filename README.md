# 🤖 Local Automated PR Reviewer Agent

This directory contains your private, modular, local background review agent. It scans for open pull requests in the active repository, filters by author, pulls comment context, performs reviews, and automatically handles the approve/request-changes lifecycle entirely from remote PR data.

This tool runs **locally on your machine**, leaving your codebase completely untouched.

---

## 📂 Directory Structure

```
gemini-pr-reviewer/
├── config.env              # ⚙️ All custom user configurations
├── gemini-pr-daemon.sh     # 🚀 The main execution daemon script
├── gemini-pr-dashboard.py  # 📊 Dynamic real-time terminal TUI dashboard
├── review-format.md        # 🎨 Enforced pull request layout preference
└── README.md               # 📖 This documentation file
```

---

## 🛠️ Requirements & Setup

Before starting the daemon, ensure you have the following CLI utilities installed and set up:
1. **GitHub CLI (`gh`)** — logged in and active (run `gh auth login`).
2. **Gemini CLI (`gemini`)** — installed globally (run `npm install -g @google/gemini-cli`).
3. **JSON Parser (`jq`)** — required for local database parsing. Install using your system's package manager:
   * **Debian / Ubuntu / Linux Mint:** `sudo apt update && sudo apt install -y jq`
   * **Fedora / CentOS / RHEL:** `sudo dnf install -y jq`
   * **Arch Linux:** `sudo pacman -S jq`
4. **Desktop Notifier (`notify-send`)** — GNOME/Linux standard for system notifications (installed by default in most desktop environments).
5. **Python 3 (`python3`)** — for running the terminal TUI dashboard (installed by default).

Ensure your terminal environment has your API key exported (if not using enterprise SSO):
```bash
export GEMINI_API_KEY="your-api-key-here"
```

---

## ⚙️ Customizing the Agent (`config.env`)

You can modify configurations on-the-fly without changing any code! Simply open `config.env` and adjust the variables:
*   `REPO_DIR`: The absolute path to your target repository clone (default: `/home/rylanevans/ilcr/ilcr-bmad/nr-ilcr`). Jump-starts the CLI into this folder automatically from anywhere.
*   `POLL_INTERVAL`: The check frequency in seconds (default: `300` = 5 minutes).
*   `MAX_DIFF_LINES`: Skips scans on massive pull requests (default: `10000` lines) to conserve API tokens and prevent crashes.
*   `IN_SCOPE_PATHS`: A regex pattern representing source directories to check (default: `"backend/src/|frontend/src/|frontend/e2e/"`). Bypasses lockfiles, assets, layout files, or documentation.
*   `BLOCKED_AUTHORS`: A space-separated list of GitHub logins to **IGNORE**. By default, it ignores automated update bots (like `@dependabot` and `@renovate`), while automatically reviewing all real developer PRs.
*   `STATE_FILE`: The database path mapping PR numbers to their last reviewed HEAD commit SHA (default: `~/.gemini/tmp/ilcr-pr-reviews.json`).
*   `REVIEW_MODE`: Set to `"manual"` to prompt in terminal, or `"automatic"` to auto-post immediately.
*   `ENTERPRISE_AUTH`: Set to `true` to use corporate SSO/ADC instead of direct API keys.

---

## 🚀 Execution Modes

### 1. Foreground Interactive Reviewer (Manual Confirmations)
When run directly in your active terminal window, the script pauses before uploading comments:
*   It performs the remote review, triggers a native desktop notification when finished, and outputs the draft markdown report directly on your screen.
*   It **pauses** and asks:
    *   *If Approved:* `🎉 Issues are RESOLVED! Would you like to submit this APPROVAL to GitHub PR #N now? [y/N]`
    *   *If Outstanding:* `🚨 Issues outstanding. Would you like to submit these REQUESTED CHANGES to GitHub PR #N now? [y/N]`
*   Typing `y` uploads it. Typing `n` cancels upload (keeping the draft saved at `/tmp/pr_review_result.md`).

**How to run:**
```bash
/home/rylanevans/gemini-pr-reviewer/gemini-pr-daemon.sh
```

### 2. Background Daemon (Hands-off Auto-Poster)
When run in the background, the script automatically bypasses confirmations, uploads the comments immediately upon completion, and alerts you via visual desktop alerts.

**How to start the daemon:**
```bash
/home/rylanevans/gemini-pr-reviewer/gemini-pr-daemon.sh > ~/gemini-pr-daemon.log 2>&1 &
```

**How to check background logs:**
```bash
tail -f ~/gemini-pr-daemon.log
```

**How to stop the daemon:**
```bash
kill $(pgrep -f "gemini-pr-reviewer/gemini-pr-daemon.sh")
```

---

## 📊 Live Terminal TUI Dashboard

To see a beautiful real-time visualization of the review daemon's state, active queue, and reviewed history without looking at raw text log streams, open a **separate terminal pane or window** (e.g. inside `tmux` or side-by-side terminal splits) and run:

```bash
/home/rylanevans/gemini-pr-reviewer/gemini-pr-dashboard.py
```
*   **Live Scanning Queue:** Shows which PR is currently being reviewed and lists remaining PRs queued in FIFO order (excluding blocked authors).
*   **Real-time Daemon State:** Dynamic text color updates indicating `Idle 💤`, `Scanning 🔍`, or `Reviewing 🤖`.
*   **Reviewed History Table:** An aligned database grid of all recently approved, changes-requested, and skipped PR commits.
*   **Flicker-free updates:** Polled and refreshed smoothly every 2 seconds.

---

## 🗄️ Understanding the Local State Database & Cache

The daemon tracks its review history inside a local JSON database at:
📁 `/home/rylanevans/.gemini/tmp/ilcr-pr-reviews.json`

For every PR scanned, it records three vital data points:
```json
  "346": {
    "last_reviewed_sha": "faacb25b6f1e8d7ffaa5f45f8f62c03957a3c44f",
    "last_comments_hash": "68b329da9893e34099c7d8ad5cb9c940",
    "status": "changes_requested"
  }
```

*   **`last_reviewed_sha` (HEAD SHA):** The current commit SHA. The agent checks this to skip re-scanning if the code hasn't changed.
*   **`last_comments_hash` (Comments MD5):** An MD5 hash of all comments posted by the PR owner. If the developer comments a message (e.g. *"This is fixed now!"*) without pushing a new commit, this hash changes, and the daemon instantly triggers a re-review!
*   **`status`:** Can be `approved`, `changes_requested`, or `skipped` (if no source files were modified).

---

## 🧹 How to Clear / Reset the Cache

If you cancelled a review midway through, adjusted your config file path rules, or want to **force the agent to re-scan a PR** immediately, you can reset the state database.

### 1. Reset a Single Specific PR (e.g., PR #346)
Run this command in your terminal to delete the cached entry for PR #346:
```bash
jq 'del(.["346"])' ~/.gemini/tmp/ilcr-pr-reviews.json > /tmp/tmp_reviews.json && mv /tmp/tmp_reviews.json ~/.gemini/tmp/ilcr-pr-reviews.json
```

### 2. Full Cache Wipe (Reset All PR Reviews)
Run this command to completely wipe the database and trigger fresh scans across every open PR:
```bash
echo "{}" > ~/.gemini/tmp/ilcr-pr-reviews.json
```

---

## 📐 Queue Architecture: Sequential FIFO Processing

The agent operates strictly on a **First-In, First-Out (FIFO) queue basis**. If multiple pull requests have new activity, they are processed sequentially, one by one.

### Why Sequential FIFO is used (The Design Rationales):
1.  **Terminal Prompt Protection:** In foreground/manual mode, running reviews in parallel would cause multiple draft reviews and `[y/N]` confirmation prompts to print directly on top of each other, scrambling your active terminal screen. Sequential queueing ensures clean, focused human confirmations.
2.  **State Database Safety:** Parallel writes would create file race conditions and JSON corruption on the `ilcr-pr-reviews.json` file. FIFO processing ensures atomic, safe database writes.
3.  **API Throttling Bypass:** Enterprise LLM endpoints enforce strict Requests Per Minute (RPM) and Tokens Per Minute (TPM) limits. Processing sequentially naturally paces your API consumption and prevents `429 Too Many Requests` rate limiting.
4.  **Zero Loss Guarantee:** Any commit pushed while the agent is actively reviewing another PR will be cleanly queued and picked up on the very next poll cycle.
