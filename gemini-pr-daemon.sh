#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -eo pipefail

# -----------------------------------------------------------------------------
# Automated Background PR Review Daemon
# 
# Usage:
#   ./gemini-pr-daemon.sh [--interval <seconds>]
# 
# Description:
#   This daemon polls for open PRs in the current repository, filters by author,
#   feeds the owner's comment history into the AI model's context, performs
#   headless reviews, tracks reviewed SHAs in a local JSON state database,
#   and automatically submits 'Approved' or 'Changes Requested' reviews.
# -----------------------------------------------------------------------------

# Detect if the script itself was started in an interactive terminal (foreground)
# Done at the absolute top before any pipes redirect stdin
if [ -t 0 ] && [ -t 1 ]; then
    IS_INTERACTIVE=true
else
    IS_INTERACTIVE=false
fi

# Load configurations from relative path
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ ! -f "$SCRIPT_DIR/config.env" ]; then
    echo "❌ Error: Configuration file 'config.env' is missing inside $SCRIPT_DIR."
    echo "   Please initialize your local config from the template:"
    echo "   cp $SCRIPT_DIR/config.env.example $SCRIPT_DIR/config.env"
    exit 1
fi

# Source configurations
source "$SCRIPT_DIR/config.env"

# Validate mandatory configuration variables (Fail-Fast Gate)
if [ -z "${REPO_DIR:-}" ]; then
    echo "❌ Error: REPO_DIR is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${POLL_INTERVAL:-}" ]; then
    echo "❌ Error: POLL_INTERVAL is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${REVIEW_MODE:-}" ]; then
    echo "❌ Error: REVIEW_MODE is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${STATE_FILE:-}" ]; then
    echo "❌ Error: STATE_FILE is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${MAX_DIFF_LINES:-}" ]; then
    echo "❌ Error: MAX_DIFF_LINES is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${IN_SCOPE_PATHS:-}" ]; then
    echo "❌ Error: IN_SCOPE_PATHS is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${BLOCKED_AUTHORS:-}" ]; then
    echo "❌ Error: BLOCKED_AUTHORS is not defined or is empty in config.env."
    exit 1
fi
if [ -z "${ENTERPRISE_AUTH:-}" ]; then
    echo "❌ Error: ENTERPRISE_AUTH is not defined or is empty in config.env."
    exit 1
fi

# Active Run-State path definitions for the TUI dashboard
ACTIVE_STATE_FILE="/home/rylanevans/.gemini/tmp/ilcr-pr-active-state.json"
mkdir -p "$(dirname "$ACTIVE_STATE_FILE")"

# Author restriction filter (Blacklist)
is_blocked_author() {
    local author="$1"
    for blocked in $BLOCKED_AUTHORS; do
        if [ "$author" == "$blocked" ]; then
            return 0 # blocked
        fi
    done
    return 1 # not blocked (allowed)
}

# Parse custom interval override
if [ "$1" == "--interval" ] && [ -n "$2" ]; then
    POLL_INTERVAL="$2"
fi

# Ensure requirements exist
if ! command -v gh &>/dev/null; then
    echo "❌ Error: 'gh' CLI is not installed."
    exit 1
fi
if ! command -v gemini &>/dev/null; then
    echo "❌ Error: 'gemini' CLI is not installed."
    exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "❌ Error: 'jq' utility is not installed."
    exit 1
fi

# Handle Authentication Checks
if [ "$ENTERPRISE_AUTH" == "true" ] || [ "$ENTERPRISE_AUTH" == "1" ]; then
    # In enterprise/Vertex AI ADC setups, GEMINI_API_KEY must be UNSET to let ADC resolve
    unset GEMINI_API_KEY
    unset GOOGLE_API_KEY
else
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "⚠️ Warning: GEMINI_API_KEY is not set in environment."
        echo "   If using corporate/enterprise SSO, set ENTERPRISE_AUTH=true in config.env to suppress this."
    fi
fi

# Ensure target repository exists and is a directory
if [ ! -d "$REPO_DIR" ]; then
    echo "❌ Error: Target repository directory '$REPO_DIR' does not exist."
    exit 1
fi

# Change directory into the target repository to execute git/gh commands
cd "$REPO_DIR"

# Initialize local state file if missing
mkdir -p "$(dirname "$STATE_FILE")"
if [ ! -f "$STATE_FILE" ]; then
    echo "{}" > "$STATE_FILE"
fi

# Write initial boot state to file immediately to populate the dashboard repo name on launch
if BOOT_REPO=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
    echo "{ \"status\": \"offline\", \"current_pr\": \"none\", \"active_repo\": \"$BOOT_REPO\", \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"queue\": [] }" > "$ACTIVE_STATE_FILE"
fi

echo "🚀 Starting PR Review Daemon..."
echo "⚙️  Interval: $POLL_INTERVAL seconds"
echo "⚙️  Repository: $REPO_DIR"
echo "⚙️  Review Mode: $REVIEW_MODE (Interactive: $IS_INTERACTIVE)"
echo "⚙️  State file: $STATE_FILE"
echo "⚙️  Blocked authors: $BLOCKED_AUTHORS"
echo "⚙️  Enterprise Authentication: ${ENTERPRISE_AUTH:-false}"
echo "--------------------------------------------------"

while true; do
    # Get active repo name
    if ! REPO_NAME=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
        echo "❌ Error: Failed to query repository remote info in $REPO_DIR. Retrying in $POLL_INTERVAL seconds..."
        echo "{ \"status\": \"offline\", \"current_pr\": \"none\", \"active_repo\": \"unknown\", \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"queue\": [] }" > "$ACTIVE_STATE_FILE"
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Identify bot/our own active GitHub user name (using the robust API call)
    BOT_USERNAME=$(gh api user --jq .login 2>/dev/null || echo "")

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔍 Scanning open PRs in $REPO_NAME..."
    echo "{ \"status\": \"scanning\", \"current_pr\": \"none\", \"active_repo\": \"$REPO_NAME\", \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"queue\": [] }" > "$ACTIVE_STATE_FILE"

    # Retrieve all open PRs
    if ! PRS_JSON=$(gh pr list --state open --json number,author,headRefOid --limit 50 2>/dev/null); then
        echo "⚠️ Warning: Failed to query open PRs from GitHub. Retrying next cycle..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Auto-prune merged/closed PR entries from the state database to keep it clean and lean
    OPEN_PR_NUMBERS=$(echo "$PRS_JSON" | jq -r '.[] | .number' | tr '\n' ' ')
    if [ -n "$OPEN_PR_NUMBERS" ] && [ -f "$STATE_FILE" ]; then
        jq --arg open_list "$OPEN_PR_NUMBERS" 'with_entries(select(.key | . as $k | ($open_list | split(" ") | index($k)) != null))' "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    # Compile the active scanning queue list dynamically into a JSON array
    # Filters out both blocked authors AND the active bot's own self pull requests
    QUEUE_JSON=$(echo "$PRS_JSON" | jq -c --arg blocked "$BLOCKED_AUTHORS" --arg bot "$BOT_USERNAME" '
      [
        .[] | 
        select(.author.login != $bot and (.author.login as $auth | ($blocked | split(" ") | index($auth)) == null)) | 
        {number: .number, author: .author.login, sha: .headRefOid}
      ]
    ')

    # Read each PR from JSON
    echo "$PRS_JSON" | jq -c '.[]' | while read -r pr_row; do
        PR_NUMBER=$(echo "$pr_row" | jq -r '.number')
        AUTHOR=$(echo "$pr_row" | jq -r '.author.login')
        HEAD_SHA=$(echo "$pr_row" | jq -r '.headRefOid')

        # Restriction 1a: Do NOT attempt to review your own pull requests (GitHub API restriction)
        if [ -n "$BOT_USERNAME" ] && [ "$AUTHOR" == "$BOT_USERNAME" ]; then
            echo "   ⏭️  Skipping PR #$PR_NUMBER: Author is yourself (@$BOT_USERNAME). GitHub does not allow self-reviews."
            # Save as skipped in state database so we don't query it again redundantly
            jq '. + { "'"$PR_NUMBER"'": { "last_reviewed_sha": "'"$HEAD_SHA"'", "last_comments_hash": "self_review", "status": "skipped" } }' "$STATE_FILE" > "${STATE_FILE}.tmp"
            mv "${STATE_FILE}.tmp" "$STATE_FILE"
            continue
        fi

        # Restriction 1b: Filter out blacklisted/blocked authors
        if is_blocked_author "$AUTHOR"; then
            continue
        fi

        # 2. Fetch PR Owner Comments for Context and Comment Hash Check
        echo "   💬 Loading comment history from PR owner @$AUTHOR..."
        OWNER_COMMENTS=$(gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | select(.author.login == "'"$AUTHOR"'") | "[Comment by @'"$AUTHOR"']: " + .body' 2>/dev/null || true)
        
        # Hash the owner comments to detect new comment activity without new commits
        if command -v md5sum &> /dev/null; then
            COMMENTS_HASH=$(echo "$OWNER_COMMENTS" | md5sum | awk '{print $1}')
        else
            COMMENTS_HASH=$(echo "$OWNER_COMMENTS" | cksum | awk '{print $1}')
        fi

        # Restriction 2: Check state database to prevent redundant scans on identical commit AND identical comments
        LAST_SHA=$(jq -r '.["'"$PR_NUMBER"'"].last_reviewed_sha // "none"' "$STATE_FILE")
        LAST_HASH=$(jq -r '.["'"$PR_NUMBER"'"].last_comments_hash // "none"' "$STATE_FILE")
        LAST_STATUS=$(jq -r '.["'"$PR_NUMBER"'"].status // "none"' "$STATE_FILE")

        if [ "$HEAD_SHA" == "$LAST_SHA" ] && [ "$COMMENTS_HASH" == "$LAST_HASH" ]; then
            # Already reviewed this specific commit and comments state. Skip.
            continue
        fi

        echo "📌 PR #$PR_NUMBER from @$AUTHOR has new activity (Commit: $HEAD_SHA, Comment Hash: $COMMENTS_HASH). Starting review..."
        echo "{ \"status\": \"reviewing\", \"current_pr\": \"$PR_NUMBER\", \"active_repo\": \"$REPO_NAME\", \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"queue\": $QUEUE_JSON }" > "$ACTIVE_STATE_FILE"

        # 3. Retrieve remote diff (remotely, never modifies local workspace files)
        gh pr diff "$PR_NUMBER" > /tmp/pr_all.diff

        # 4. Filter in-scope paths
        awk -v pattern="$IN_SCOPE_PATHS" '
            /^diff --git/ {
                if ($0 ~ pattern) { print_block=1 } else { print_block=0 }
            }
            {
                if (print_block) { print }
            }
        ' /tmp/pr_all.diff > /tmp/pr_filtered.diff

        CHANGED_LINES=$(wc -l < /tmp/pr_filtered.diff)
        if [ "$CHANGED_LINES" -eq 0 ]; then
            echo "   ⏭️  Skipping PR #$PR_NUMBER: No in-scope source files modified."
            # Mark as skipped in state database to prevent checking it again
            jq '. + { "'"$PR_NUMBER"'": { "last_reviewed_sha": "'"$HEAD_SHA"'", "last_comments_hash": "'"$COMMENTS_HASH"'", "status": "skipped" } }' "$STATE_FILE" > "${STATE_FILE}.tmp"
            mv "${STATE_FILE}.tmp" "$STATE_FILE"
            continue
        fi

        if [ "$CHANGED_LINES" -gt "$MAX_DIFF_LINES" ]; then
            echo "   ⚠️ Skipping PR #$PR_NUMBER: Diff too large ($CHANGED_LINES lines)."
            continue
        fi

        # 5. Fetch PR Owner Comments for Context
        CONTEXT_PROMPT=""
        if [ -n "$OWNER_COMMENTS" ]; then
            CONTEXT_PROMPT="Note: The PR owner (@$AUTHOR) has commented the following explanations and replies on this PR. Use this context to see if they have answered your previous feedback or provided specific rationales for their code choices:
$OWNER_COMMENTS
"
        fi

        # 6. Fetch Our Previous Review Feedback (to check if the new commit actually addresses it)
        echo "   🔍 Loading previous review feedback posted by bot (@$BOT_USERNAME)..."
        BOT_PREVIOUS_FEEDBACK=""
        if [ -n "$BOT_USERNAME" ]; then
            BOT_PREVIOUS_FEEDBACK=$(gh pr view "$PR_NUMBER" --json reviews --jq '.reviews[] | select(.author.login == "'"$BOT_USERNAME"'") | .body' 2>/dev/null || true)
        fi
        
        PREVIOUS_FEEDBACK_PROMPT=""
        RE_REVIEW_INSTRUCTION=""
        if [ -n "$BOT_PREVIOUS_FEEDBACK" ]; then
            PREVIOUS_FEEDBACK_PROMPT="Note: You have already reviewed this PR previously and requested specific changes. Here is the feedback you submitted:
--- START OF PREVIOUS FEEDBACK ---
$BOT_PREVIOUS_FEEDBACK
--- END OF PREVIOUS FEEDBACK ---
"
            # If the previous scan status was 'changes_requested', force the AI into Verification-Only Mode
            if [ "$LAST_STATUS" == "changes_requested" ]; then
                RE_REVIEW_INSTRUCTION="⚠️ CRITICAL RE-REVIEW VERIFICATION MODE:
This is a follow-up review. The PR previously had changes requested. 
Your SOLE and exclusive objective in this session is to verify if the developer has successfully fixed the specific defects listed in the 'Previous Feedback' above.
- DO NOT perform a brand-new code review from scratch.
- DO NOT scan for new, unrelated bugs or expand the scope of the review.
- If the original defects (e.g. the schedule2.jrxml page footer) are resolved in the new diff, you MUST output the verdict APPROVED.
- If the original defects are still outstanding, output CHANGES_REQUESTED and list ONLY the unresolved original defects from the Previous Feedback.
"
            fi
        fi

        # Load layout formatting instruction dynamically
        FORMAT_INSTRUCTION=""
        if [ -f "$SCRIPT_DIR/review-format.md" ]; then
            FORMAT_INSTRUCTION="You MUST format your pull request review EXACTLY according to the layout rules defined in this template:
--- START OF LAYOUT TEMPLATE ---
$(cat "$SCRIPT_DIR/review-format.md")
--- END OF LAYOUT TEMPLATE ---
"
        fi

        # 7. Execute Headless Gemini Review
        echo "   🤖 Running AI code analysis..."
        export GEMINI_CLI_TRUST_WORKSPACE="true"

        # Ask the model to review and supply a machine-parseable [VERDICT] line at the end
        # We redirect the filtered diff into standard input of gemini to bypass ARG_MAX limitations completely
        gemini --yolo -p "You are an expert software engineer and automated code reviewer. Review the following code diff passed via standard input for pull request #$PR_NUMBER. Look for critical bugs, memory leaks, performance issues, logic flaws, or type-safety bypasses.

Your review must critically analyze the code changes from three specialized lenses:
1. ADVERSARIAL (Blind Hunter): Search for logic flaws, race conditions, bad assertions, false positives, or brittle waiting/dynamic elements.
2. EDGE-CASE (Edge Case Hunter): Evaluate boundary conditions, negative bounds, timing races, and robust error fallbacks.
3. VERIFICATION-GAP: Contrast the changes against enterprise standards, checking for proper declarations, type safety, and clean abstractions.
        
$FORMAT_INSTRUCTION

At the absolute end of your review response, append exactly one of the following lines to indicate your verdict:
If the code has zero critical defects, or if all previously requested changes/comments from you and the PR owner are fully resolved, append exactly:
[VERDICT]: APPROVED

If there are still critical bugs, logic flaws, or required code adjustments, append exactly:
[VERDICT]: CHANGES_REQUESTED

$CONTEXT_PROMPT
$PREVIOUS_FEEDBACK_PROMPT
$RE_REVIEW_INSTRUCTION" < /tmp/pr_filtered.diff > /tmp/pr_review_result.md

        # Clean the verdict marker from the user-facing report and extract the status
        if grep -q "\[VERDICT\]: APPROVED" /tmp/pr_review_result.md; then
            VERDICT="APPROVED"
            STATUS="approved"
        else
            VERDICT="CHANGES_REQUESTED"
            STATUS="changes_requested"
        fi

        # Post-process the file to remove any internal CLI tool announcements,
        # thought preambles, or conversational noise (e.g. "I will run...", "I am...")
        sed -i '/^I will/d' /tmp/pr_review_result.md
        sed -i '/^I am/d' /tmp/pr_review_result.md
        sed -i '/^I have/d' /tmp/pr_review_result.md
        sed -i '/\[VERDICT\]:/d' /tmp/pr_review_result.md

        # Trigger Linux Desktop Notification toast (if notify-send is available)
        if command -v notify-send &> /dev/null; then
            notify-send -i dialog-information "🤖 PR Review Completed" "PR #$PR_NUMBER by @$AUTHOR reviewed.\nVerdict: $VERDICT." || true
        fi

        # Determine if we should prompt for confirmation
        # We only prompt if REVIEW_MODE is "manual" AND the daemon was started in an interactive terminal
        POST_CONFIRMED=true
        if [ "$REVIEW_MODE" == "manual" ] && [ "$IS_INTERACTIVE" == "true" ]; then
            echo -e "\n==================== DRAFT REVIEW FOR PR #$PR_NUMBER ====================\n"
            cat /tmp/pr_review_result.md
            echo -e "\n=========================================================================\n"
            if [ "$VERDICT" == "APPROVED" ]; then
                # Redirect read input from /dev/tty so it reads from keyboard even inside the piped loop
                read -p "🎉 Issues are RESOLVED! Would you like to submit this APPROVAL to GitHub PR #$PR_NUMBER now? [y/N] " -n 1 -r < /dev/tty
            else
                # Redirect read input from /dev/tty so it reads from keyboard even inside the piped loop
                read -p "🚨 Issues outstanding. Would you like to submit these REQUESTED CHANGES to GitHub PR #$PR_NUMBER now? [y/N] " -n 1 -r < /dev/tty
            fi
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                POST_CONFIRMED=false
                echo "   ❌ Post cancelled. Draft review saved locally to: /tmp/pr_review_result.md"
            fi
        fi

        if [ "$POST_CONFIRMED" = true ]; then
            # 7. Post appropriate review type
            if [ "$VERDICT" == "APPROVED" ]; then
                echo "   ✅ PR #$PR_NUMBER is Approved! Submitting approval..."
                gh pr review "$PR_NUMBER" --approve -F /tmp/pr_review_result.md
            else
                echo "   🚨 PR #$PR_NUMBER has issues. Submitting requested changes..."
                gh pr review "$PR_NUMBER" --request-changes -F /tmp/pr_review_result.md
            fi

            # 8. Save progress in state database
            jq '. + { "'"$PR_NUMBER"'": { "last_reviewed_sha": "'"$HEAD_SHA"'", "last_comments_hash": "'"$COMMENTS_HASH"'", "status": "'"$STATUS"'" } }' "$STATE_FILE" > "${STATE_FILE}.tmp"
            mv "${STATE_FILE}.tmp" "$STATE_FILE"
            echo "   ✅ PR #$PR_NUMBER state saved. Status: $STATUS."
        else
            echo "   ℹ️ PR #$PR_NUMBER state was not updated so you can re-run the review."
        fi
    done

    # Reset active status JSON to sleeping between scan loops
    echo "{ \"status\": \"sleeping\", \"current_pr\": \"none\", \"active_repo\": \"$REPO_NAME\", \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"queue\": [] }" > "$ACTIVE_STATE_FILE"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 😴 Scan complete. Sleeping for $POLL_INTERVAL seconds..."
    sleep "$POLL_INTERVAL"
done
