#!/bin/bash

# MCP Shell Server for Claude Code CLI (Enhanced Version with Parallel Support)
# This server implements the MCP protocol to call Claude Code CLI locally
# Supports: claude.generate, claude.edit, claude.refactor (with retry, timeout, model selection)
# Features: Parallel execution of tools/call requests

# Log to stderr with timestamp (HH:mm:ss.fff format)
log() {
    timestamp=$(date +"%H:%M:%S.%3N" 2>/dev/null || date +"%H:%M:%S")
    echo "[$timestamp] $*" >&2
}

# Atomic output to stdout (uses flock if available, otherwise direct output)
# This ensures parallel responses don't interleave
LOCK_FILE="/tmp/mcp-claude-stdout.lock"
atomic_output() {
    if command -v flock >/dev/null 2>&1; then
        flock "$LOCK_FILE" -c "printf '%s\n' \"$1\""
    else
        # Fallback: single printf should be atomic for lines < PIPE_BUF (4096)
        printf '%s\n' "$1"
    fi
}

log "Starting Claude Code MCP server (Enhanced + Parallel)..."

# Export functions for subshells
export -f log
export -f atomic_output
export LOCK_FILE

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is not installed. Please install jq first."
    exit 1
fi

# Helper function: Execute AI command with retry and timeout
# Args: prompt, model, timeout_sec, max_retries
run_ai_with_retry() {
    ai_prompt="$1"
    ai_model="${2:-haiku}"
    timeout_sec="${3:-660}"
    max_retries="${4:-3}"

    # Map model names to Claude CLI format (Updated: 2025-11)
    case "$ai_model" in
        "haiku"|"Haiku")
            model_flag="claude-haiku-4-5-20251001"
            ;;
        "sonnet"|"Sonnet")
            model_flag="claude-sonnet-4-5-20250929"
            ;;
        "opus"|"Opus"|"Opus 4.5")
            model_flag="claude-opus-4-5-20251101"
            ;;
        *)
            log "WARNING: Unknown model '$ai_model', using haiku as default"
            model_flag="claude-haiku-4-5-20251001"
            ;;
    esac

    log "Model: $model_flag, Timeout: ${timeout_sec}s, Max retries: $max_retries"
    log "Prompt preview: ${ai_prompt:0:100}..."

    attempt=0
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))
        log "Attempt $attempt/$max_retries"

        # Execute with timeout (if available)
        if command -v timeout >/dev/null 2>&1; then
            ai_result=$(echo "$ai_prompt" | timeout ${timeout_sec}s claude --model "$model_flag" --dangerously-skip-permissions 2>&1)
            exit_code=$?
        else
            ai_result=$(echo "$ai_prompt" | claude --model "$model_flag" --dangerously-skip-permissions 2>&1)
            exit_code=$?
        fi

        # Check exit code
        if [ $exit_code -eq 0 ]; then
            log "Success on attempt $attempt"
            echo "$ai_result"
            return 0
        elif [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
            # Timeout error (124 = timeout command, 137 = SIGKILL)
            log "WARNING: Command timeout on attempt $attempt"
            if [ $attempt -lt $max_retries ]; then
                log "Waiting 5 seconds before retry..."
                sleep 5
            fi
        else
            # Other errors
            log "ERROR: Command failed with exit code $exit_code on attempt $attempt"
            if [ $attempt -lt $max_retries ]; then
                log "Waiting 2 seconds before retry..."
                sleep 2
            else
                echo "$ai_result"
                return $exit_code
            fi
        fi
    done

    log "ERROR: Max retries ($max_retries) reached"
    echo "Max retries reached after $max_retries attempts"
    return 1
}
export -f run_ai_with_retry

# Helper function: Execute AI and validate JSON response with retry
# Args: prompt, model, max_retries
run_ai_json_with_retry() {
    json_prompt="$1"
    json_model="${2:-haiku}"
    json_max_retries="${3:-3}"

    attempt=0
    errors=""

    while [ $attempt -lt $json_max_retries ]; do
        attempt=$((attempt + 1))
        log "JSON attempt $attempt/$json_max_retries"

        # Call AI
        ai_output=$(run_ai_with_retry "$json_prompt" "$json_model" 660 1)
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
            error_msg="AI execution failed: $ai_output"
            log "ERROR: $error_msg"
            errors="$errors\n[$attempt] $error_msg"
            continue
        fi

        # Extract JSON content (find first { to last })
        json_content=$(echo "$ai_output" | sed -n '/{/,/}/p' | sed -n '1h;1!H;${g;s/.*\({.*}\).*/\1/p;}')

        # Validate JSON
        if echo "$json_content" | jq empty 2>/dev/null; then
            log "JSON validation successful"
            echo "$json_content"
            return 0
        else
            error_msg="JSON parsing failed"
            log "ERROR: $error_msg"
            errors="$errors\n[$attempt] $error_msg"

            if [ $attempt -lt $json_max_retries ]; then
                log "Waiting 2 seconds before retry..."
                sleep 2
            fi
        fi
    done

    log "ERROR: Max JSON retries ($json_max_retries) reached"
    echo "{\"error\":\"Max retries reached\",\"attempts\":$json_max_retries,\"errors\":\"$errors\"}"
    return 1
}
export -f run_ai_json_with_retry

# Main loop: read JSON-RPC requests from stdin
while IFS= read -r line; do
    # Skip empty lines
    [ -z "$line" ] && continue

    log "Received: ${line:0:100}..."

    # Parse JSON-RPC request
    id=$(echo "$line" | jq -r '.id // empty')
    method=$(echo "$line" | jq -r '.method // empty')

    # Handle MCP protocol methods
    case "$method" in
        initialize)
            log "Handling initialize request"
            # Respond with server capabilities
            cat <<EOF
{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"claude-shell","version":"1.0.0"}}}
EOF
            ;;

        initialized)
            log "Received initialized notification"
            # No response needed for notifications
            ;;

        tools/list)
            log "Listing available tools"
            cat <<'EOF'
{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"claude.generate","description":"Generate code or text via Claude Code CLI with retry and model selection","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Prompt to pass to Claude CLI"},"model":{"type":"string","description":"Model to use (haiku, sonnet, opus). Default: haiku","enum":["haiku","sonnet","opus","Haiku","Sonnet","Opus","Opus 4.5"]},"timeout":{"type":"number","description":"Timeout in seconds. Default: 660"},"maxRetries":{"type":"number","description":"Maximum retry attempts. Default: 3"}},"required":["prompt"]}},{"name":"claude.edit","description":"Edit files via Claude Code CLI with retry and model selection","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Edit instructions"},"model":{"type":"string","description":"Model to use (haiku, sonnet, opus). Default: haiku"},"timeout":{"type":"number","description":"Timeout in seconds. Default: 660"},"maxRetries":{"type":"number","description":"Maximum retry attempts. Default: 3"}},"required":["prompt"]}},{"name":"claude.refactor","description":"Refactor code via Claude Code CLI with retry and model selection","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Refactoring instructions"},"model":{"type":"string","description":"Model to use (haiku, sonnet, opus). Default: haiku"},"timeout":{"type":"number","description":"Timeout in seconds. Default: 660"},"maxRetries":{"type":"number","description":"Maximum retry attempts. Default: 3"}},"required":["prompt"]}},{"name":"claude.generate.json","description":"Generate JSON response with validation and retry","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Prompt for JSON generation"},"model":{"type":"string","description":"Model to use. Default: haiku"},"maxRetries":{"type":"number","description":"Maximum retry attempts for JSON validation. Default: 3"}},"required":["prompt"]}},{"name":"claude.edit.json","description":"Edit with JSON response validation and retry","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Edit instructions expecting JSON response"},"model":{"type":"string","description":"Model to use. Default: haiku"},"maxRetries":{"type":"number","description":"Maximum retry attempts for JSON validation. Default: 3"}},"required":["prompt"]}}]}}
EOF
            ;;

        tools/call)
            log "Handling tools/call request (parallel mode)"

            # Extract tool name and arguments
            tool_name=$(echo "$line" | jq -r '.params.name // empty')
            prompt=$(echo "$line" | jq -r '.params.arguments.prompt // empty')
            model=$(echo "$line" | jq -r '.params.arguments.model // "haiku"')
            timeout=$(echo "$line" | jq -r '.params.arguments.timeout // "660"')
            max_retries=$(echo "$line" | jq -r '.params.arguments.maxRetries // "3"')

            log "Tool: $tool_name (id=$id)"
            log "Model: $model, Timeout: ${timeout}s, Max retries: $max_retries"
            log "Prompt: ${prompt:0:50}..."

            # Validate tool name (sync - fast validation before spawning)
            case "$tool_name" in
                claude.generate|claude.edit|claude.refactor|claude.generate.json|claude.edit.json)
                    ;;
                *)
                    log "ERROR: Unknown tool: $tool_name"
                    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown tool: %s"}}\n' "$id" "$tool_name"
                    continue
                    ;;
            esac

            # Check if claude CLI is available (sync - fast check)
            if ! command -v claude >/dev/null 2>&1; then
                log "ERROR: claude CLI not found"
                printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"claude CLI not found"}}\n' "$id"
                continue
            fi

            # Execute in background subshell for parallel processing
            (
                _id="$id"
                _tool_name="$tool_name"
                _prompt="$prompt"
                _model="$model"
                _timeout="$timeout"
                _max_retries="$max_retries"

                log "[BG $_id] Starting $_tool_name"

                # Execute based on tool type
                case "$_tool_name" in
                    claude.generate|claude.edit|claude.refactor)
                        # Standard text response with retry
                        result=$(run_ai_with_retry "$_prompt" "$_model" "$_timeout" "$_max_retries")
                        exit_code=$?

                        if [ $exit_code -ne 0 ]; then
                            log "[BG $_id] ERROR: AI execution failed"
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Claude CLI error","data":%s}}' \
                                "$_id" \
                                "$(printf "%s" "$result" | jq -R -s '.')")
                        else
                            log "[BG $_id] Success: Text response received"
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}]}}' \
                                "$_id" \
                                "$(printf "%s" "$result" | jq -R -s '.')")
                        fi
                        ;;

                    claude.generate.json|claude.edit.json)
                        # JSON response with validation and retry
                        json_result=$(run_ai_json_with_retry "$_prompt" "$_model" "$_max_retries")
                        exit_code=$?

                        if [ $exit_code -ne 0 ]; then
                            log "[BG $_id] ERROR: JSON generation/validation failed"
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"JSON validation error","data":%s}}' \
                                "$_id" \
                                "$(printf "%s" "$json_result" | jq -R -s '.')")
                        else
                            log "[BG $_id] Success: Valid JSON response received"
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}]}}' \
                                "$_id" \
                                "$(printf "%s" "$json_result" | jq -R -s '.')")
                        fi
                        ;;
                esac

                # Output response atomically
                atomic_output "$response"
                log "[BG $_id] Response sent"
            ) &

            log "Spawned background process for id=$id"
            ;;

        *)
            log "ERROR: Unsupported method: $method"
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found: %s"}}\n' "$id" "$method"
            ;;
    esac
done
