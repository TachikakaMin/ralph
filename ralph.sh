#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool codex|amp|claude] [max_iterations]

set -e

# Parse arguments
TOOL="codex"  # Default to codex
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "codex" && "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'codex', 'amp', or 'claude'."
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
LOG_DIR="$SCRIPT_DIR/logs"

build_runtime_prompt() {
  local base_prompt_file="$1"
  local runtime_prompt_file="$2"

  cat > "$runtime_prompt_file" <<EOF
# Ralph Runtime Context

You are working in the project root: $PROJECT_ROOT

Ralph control files live here:
- PRD: $PRD_FILE
- Progress log: $PROGRESS_FILE
- Ralph directory: $SCRIPT_DIR

If the instructions below mention \`prd.json\` or \`progress.txt\`, use the files above.

EOF
  cat "$base_prompt_file" >> "$runtime_prompt_file"
}

run_with_pty() {
  local command="$1"
  local output_log_file="$2"

  set +e
  script -q -f -e -c "$command" "$output_log_file"
  TOOL_EXIT=$?
  set -e
}

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "ralph/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

mkdir -p "$LOG_DIR"

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # Run the selected tool with the ralph prompt
  RUNTIME_PROMPT_FILE="$(mktemp)"
  LAST_MESSAGE_FILE=""
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_LOG_FILE="$LOG_DIR/${TIMESTAMP}-iter${i}-${TOOL}.log"
  TOOL_EXIT=0
  COMPLETE_FOUND=0

  echo "Streaming live output to $OUTPUT_LOG_FILE"

  case "$TOOL" in
    amp)
      build_runtime_prompt "$SCRIPT_DIR/prompt.md" "$RUNTIME_PROMPT_FILE"
      printf -v TOOL_COMMAND 'cd %q && amp --dangerously-allow-all < %q' "$PROJECT_ROOT" "$RUNTIME_PROMPT_FILE"
      run_with_pty "bash -lc $(printf '%q' "$TOOL_COMMAND")" "$OUTPUT_LOG_FILE"
      ;;
    claude)
      build_runtime_prompt "$SCRIPT_DIR/CLAUDE.md" "$RUNTIME_PROMPT_FILE"
      # Claude Code: use --dangerously-skip-permissions for autonomous operation, --print for output
      printf -v TOOL_COMMAND 'cd %q && claude --dangerously-skip-permissions --print < %q' "$PROJECT_ROOT" "$RUNTIME_PROMPT_FILE"
      run_with_pty "bash -lc $(printf '%q' "$TOOL_COMMAND")" "$OUTPUT_LOG_FILE"
      ;;
    codex)
      build_runtime_prompt "$SCRIPT_DIR/CODEX.md" "$RUNTIME_PROMPT_FILE"
      LAST_MESSAGE_FILE="$(mktemp)"
      printf -v TOOL_COMMAND 'cd %q && codex exec --full-auto --color never -o %q - < %q' "$PROJECT_ROOT" "$LAST_MESSAGE_FILE" "$RUNTIME_PROMPT_FILE"
      run_with_pty "bash -lc $(printf '%q' "$TOOL_COMMAND")" "$OUTPUT_LOG_FILE"
      if [[ -s "$LAST_MESSAGE_FILE" ]]; then
        if grep -q "<promise>COMPLETE</promise>" "$LAST_MESSAGE_FILE"; then
          COMPLETE_FOUND=1
        fi
        {
          echo ""
          echo "----- Codex Final Message -----"
          cat "$LAST_MESSAGE_FILE"
        } | tee -a "$OUTPUT_LOG_FILE"
      fi
      ;;
  esac

  OUTPUT="$(cat "$OUTPUT_LOG_FILE")"
  if [[ "$TOOL_EXIT" -ne 0 ]]; then
    echo "Tool exited with status $TOOL_EXIT" | tee -a "$OUTPUT_LOG_FILE"
    OUTPUT="${OUTPUT}"$'\n'"Tool exited with status $TOOL_EXIT"
  fi

  if [[ "$TOOL" != "codex" ]] && echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    COMPLETE_FOUND=1
  fi

  rm -f "$RUNTIME_PROMPT_FILE"
  if [[ -n "$LAST_MESSAGE_FILE" ]]; then
    rm -f "$LAST_MESSAGE_FILE"
  fi
  
  # Check for completion signal
  if [[ "$COMPLETE_FOUND" -eq 1 ]]; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    echo "Latest iteration log: $OUTPUT_LOG_FILE"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE and $LOG_DIR for status."
exit 1
