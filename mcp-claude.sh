#!/bin/bash

# MCP Shell Server for Claude Code CLI (Enhanced Version v2.0)
# This server implements the MCP protocol to call Claude Code CLI locally
# Supports: claude_generate, claude_edit, claude_refactor, claude_generate_json, claude_edit_json
# Features:
#   - Parallel execution of tools/call requests
#   - JSON output format (default)
#   - JSON Schema validation
#   - Max turns control
#   - System prompt customization
#   - Tool permission control
#   - Verbose mode for debugging

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
        flock "$LOCK_FILE" -c "printf '%s\\n' \"$1\""
    else
        # Fallback: single printf should be atomic for lines < PIPE_BUF (4096)
        printf '%s\n' "$1"
    fi
}

log "Starting Claude Code MCP server (Enhanced v2.0)..."

# Export functions for subshells
export -f log
export -f atomic_output
export LOCK_FILE

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is not installed. Please install jq first."
    exit 1
fi

# Helper function: Build Claude CLI command arguments
# Returns the command arguments array as a string
build_claude_args() {
    local model="$1"
    local max_turns="$2"
    local output_format="$3"
    local json_schema="$4"
    local system_prompt="$5"
    local append_system_prompt="$6"
    local allowed_tools="$7"
    local disallowed_tools="$8"
    local add_dirs="$9"
    local verbose="${10}"

    # Map model names to Claude CLI format (Updated: 2025-11)
    local model_flag
    case "$model" in
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
            log "WARNING: Unknown model '$model', using haiku as default"
            model_flag="claude-haiku-4-5-20251001"
            ;;
    esac

    # Build arguments array
    local args="--model $model_flag --dangerously-skip-permissions -p"

    # Output format (default: json for structured output)
    if [ -n "$output_format" ]; then
        args="$args --output-format $output_format"
    else
        args="$args --output-format json"
    fi

    # Max turns (limit agent iterations)
    if [ -n "$max_turns" ] && [ "$max_turns" != "null" ]; then
        args="$args --max-turns $max_turns"
    fi

    # JSON Schema validation
    if [ -n "$json_schema" ] && [ "$json_schema" != "null" ]; then
        args="$args --json-schema '$json_schema'"
    fi

    # System prompt (replace default)
    if [ -n "$system_prompt" ] && [ "$system_prompt" != "null" ]; then
        args="$args --system-prompt '$system_prompt'"
    fi

    # Append system prompt (add to default)
    if [ -n "$append_system_prompt" ] && [ "$append_system_prompt" != "null" ]; then
        args="$args --append-system-prompt '$append_system_prompt'"
    fi

    # Allowed tools (space-separated list)
    if [ -n "$allowed_tools" ] && [ "$allowed_tools" != "null" ]; then
        for tool in $allowed_tools; do
            args="$args --allowedTools \"$tool\""
        done
    fi

    # Disallowed tools (space-separated list)
    if [ -n "$disallowed_tools" ] && [ "$disallowed_tools" != "null" ]; then
        for tool in $disallowed_tools; do
            args="$args --disallowedTools \"$tool\""
        done
    fi

    # Additional directories (space-separated list)
    if [ -n "$add_dirs" ] && [ "$add_dirs" != "null" ]; then
        for dir in $add_dirs; do
            args="$args --add-dir \"$dir\""
        done
    fi

    # Verbose mode
    if [ "$verbose" = "true" ]; then
        args="$args --verbose"
    fi

    echo "$args"
}
export -f build_claude_args

# Helper function: Execute AI command with retry and timeout
# Args: prompt, model, timeout_sec, max_retries, max_turns, output_format, json_schema,
#       system_prompt, append_system_prompt, allowed_tools, disallowed_tools, add_dirs, verbose
run_ai_with_retry() {
    local ai_prompt="$1"
    local ai_model="${2:-haiku}"
    local timeout_sec="${3:-660}"
    local max_retries="${4:-3}"
    local max_turns="$5"
    local output_format="${6:-json}"
    local json_schema="$7"
    local system_prompt="$8"
    local append_system_prompt="$9"
    local allowed_tools="${10}"
    local disallowed_tools="${11}"
    local add_dirs="${12}"
    local verbose="${13}"

    # Build command arguments
    local cmd_args
    cmd_args=$(build_claude_args "$ai_model" "$max_turns" "$output_format" "$json_schema" \
        "$system_prompt" "$append_system_prompt" "$allowed_tools" "$disallowed_tools" "$add_dirs" "$verbose")

    log "Command args: $cmd_args"
    log "Timeout: ${timeout_sec}s, Max retries: $max_retries"
    log "Prompt preview: ${ai_prompt:0:100}..."

    local attempt=0
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))
        log "Attempt $attempt/$max_retries"

        local ai_result
        local exit_code

        # Execute with timeout (if available)
        if command -v timeout >/dev/null 2>&1; then
            ai_result=$(echo "$ai_prompt" | timeout ${timeout_sec}s bash -c "claude $cmd_args" 2>&1)
            exit_code=$?
        else
            ai_result=$(echo "$ai_prompt" | bash -c "claude $cmd_args" 2>&1)
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
            log "Error output: ${ai_result:0:200}"
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

# Helper function: Extract result text from JSON output
extract_result_text() {
    local json_output="$1"

    # Try to extract 'result' field from JSON output
    local result
    result=$(echo "$json_output" | jq -r '.result // empty' 2>/dev/null)

    if [ -n "$result" ] && [ "$result" != "null" ]; then
        echo "$result"
    else
        # Fallback: return original output
        echo "$json_output"
    fi
}
export -f extract_result_text

# Helper function: Execute AI and validate JSON response with retry
# Args: prompt, model, max_retries, json_schema, system_prompt, append_system_prompt
run_ai_json_with_retry() {
    local json_prompt="$1"
    local json_model="${2:-haiku}"
    local json_max_retries="${3:-3}"
    local json_schema="$4"
    local system_prompt="$5"
    local append_system_prompt="$6"

    local attempt=0
    local errors=""

    while [ $attempt -lt $json_max_retries ]; do
        attempt=$((attempt + 1))
        log "JSON attempt $attempt/$json_max_retries"

        # Call AI with JSON output format
        local ai_output
        ai_output=$(run_ai_with_retry "$json_prompt" "$json_model" 660 1 "" "json" "$json_schema" \
            "$system_prompt" "$append_system_prompt" "" "" "" "")
        local exit_code=$?

        if [ $exit_code -ne 0 ]; then
            local error_msg="AI execution failed: $ai_output"
            log "ERROR: $error_msg"
            errors="$errors\n[$attempt] $error_msg"
            continue
        fi

        # Extract result text
        local result_text
        result_text=$(extract_result_text "$ai_output")

        # Try to extract JSON content (find first { to last })
        local json_content
        json_content=$(echo "$result_text" | sed -n '/{/,/}/p' | sed -n '1h;1!H;${g;s/.*\({.*}\).*/\1/p;}')

        # If no JSON found in result, try the raw output
        if [ -z "$json_content" ]; then
            json_content=$(echo "$ai_output" | sed -n '/{/,/}/p' | sed -n '1h;1!H;${g;s/.*\({.*}\).*/\1/p;}')
        fi

        # Validate JSON
        if echo "$json_content" | jq empty 2>/dev/null; then
            log "JSON validation successful"
            echo "$json_content"
            return 0
        else
            local error_msg="JSON parsing failed"
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

# Generate tools list JSON
generate_tools_list() {
    cat <<'TOOLS_EOF'
{"jsonrpc":"2.0","id":1,"result":{"tools":[
  {
    "name": "claude_generate",
    "description": "Generate code or text via Claude Code CLI with retry and model selection",
    "inputSchema": {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Prompt to pass to Claude CLI"},
        "model": {"type": "string", "description": "Model to use (haiku, sonnet, opus). Default: haiku", "enum": ["haiku", "sonnet", "opus", "Haiku", "Sonnet", "Opus", "Opus 4.5"]},
        "timeout": {"type": "number", "description": "Timeout in seconds. Default: 660"},
        "maxRetries": {"type": "number", "description": "Maximum retry attempts. Default: 3"},
        "maxTurns": {"type": "number", "description": "Maximum agent turns (iterations). Default: unlimited"},
        "outputFormat": {"type": "string", "description": "Output format: text, json, stream-json. Default: json", "enum": ["text", "json", "stream-json"]},
        "systemPrompt": {"type": "string", "description": "Replace default system prompt"},
        "appendSystemPrompt": {"type": "string", "description": "Append to default system prompt"},
        "allowedTools": {"type": "array", "items": {"type": "string"}, "description": "Additional tools to allow without asking"},
        "disallowedTools": {"type": "array", "items": {"type": "string"}, "description": "Tools to disallow"},
        "addDirs": {"type": "array", "items": {"type": "string"}, "description": "Additional directories to access"},
        "verbose": {"type": "boolean", "description": "Enable verbose logging. Default: false"}
      },
      "required": ["prompt"]
    }
  },
  {
    "name": "claude_edit",
    "description": "Edit files via Claude Code CLI with retry and model selection",
    "inputSchema": {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Edit instructions"},
        "model": {"type": "string", "description": "Model to use (haiku, sonnet, opus). Default: haiku"},
        "timeout": {"type": "number", "description": "Timeout in seconds. Default: 660"},
        "maxRetries": {"type": "number", "description": "Maximum retry attempts. Default: 3"},
        "maxTurns": {"type": "number", "description": "Maximum agent turns. Default: unlimited"},
        "outputFormat": {"type": "string", "description": "Output format. Default: json", "enum": ["text", "json", "stream-json"]},
        "systemPrompt": {"type": "string", "description": "Replace default system prompt"},
        "appendSystemPrompt": {"type": "string", "description": "Append to default system prompt"},
        "allowedTools": {"type": "array", "items": {"type": "string"}, "description": "Additional tools to allow"},
        "disallowedTools": {"type": "array", "items": {"type": "string"}, "description": "Tools to disallow"},
        "addDirs": {"type": "array", "items": {"type": "string"}, "description": "Additional directories"},
        "verbose": {"type": "boolean", "description": "Enable verbose logging"}
      },
      "required": ["prompt"]
    }
  },
  {
    "name": "claude_refactor",
    "description": "Refactor code via Claude Code CLI with retry and model selection",
    "inputSchema": {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Refactoring instructions"},
        "model": {"type": "string", "description": "Model to use (haiku, sonnet, opus). Default: haiku"},
        "timeout": {"type": "number", "description": "Timeout in seconds. Default: 660"},
        "maxRetries": {"type": "number", "description": "Maximum retry attempts. Default: 3"},
        "maxTurns": {"type": "number", "description": "Maximum agent turns. Default: unlimited"},
        "outputFormat": {"type": "string", "description": "Output format. Default: json", "enum": ["text", "json", "stream-json"]},
        "systemPrompt": {"type": "string", "description": "Replace default system prompt"},
        "appendSystemPrompt": {"type": "string", "description": "Append to default system prompt"},
        "allowedTools": {"type": "array", "items": {"type": "string"}, "description": "Additional tools to allow"},
        "disallowedTools": {"type": "array", "items": {"type": "string"}, "description": "Tools to disallow"},
        "addDirs": {"type": "array", "items": {"type": "string"}, "description": "Additional directories"},
        "verbose": {"type": "boolean", "description": "Enable verbose logging"}
      },
      "required": ["prompt"]
    }
  },
  {
    "name": "claude_generate_json",
    "description": "Generate JSON response with validation and retry",
    "inputSchema": {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Prompt for JSON generation"},
        "model": {"type": "string", "description": "Model to use. Default: haiku"},
        "maxRetries": {"type": "number", "description": "Maximum retry attempts for JSON validation. Default: 3"},
        "jsonSchema": {"type": "string", "description": "JSON Schema to validate output against"},
        "systemPrompt": {"type": "string", "description": "Replace default system prompt"},
        "appendSystemPrompt": {"type": "string", "description": "Append to default system prompt"}
      },
      "required": ["prompt"]
    }
  },
  {
    "name": "claude_edit_json",
    "description": "Edit with JSON response validation and retry",
    "inputSchema": {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Edit instructions expecting JSON response"},
        "model": {"type": "string", "description": "Model to use. Default: haiku"},
        "maxRetries": {"type": "number", "description": "Maximum retry attempts for JSON validation. Default: 3"},
        "jsonSchema": {"type": "string", "description": "JSON Schema to validate output against"},
        "systemPrompt": {"type": "string", "description": "Replace default system prompt"},
        "appendSystemPrompt": {"type": "string", "description": "Append to default system prompt"}
      },
      "required": ["prompt"]
    }
  }
]}}
TOOLS_EOF
}

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
{"jsonrpc":"2.0","id":$id,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"claude-shell","version":"2.0.0"}}}
EOF
            ;;

        initialized)
            log "Received initialized notification"
            # No response needed for notifications
            ;;

        tools/list)
            log "Listing available tools"
            generate_tools_list
            ;;

        tools/call)
            log "Handling tools/call request (parallel mode)"

            # Extract tool name and all arguments
            tool_name=$(echo "$line" | jq -r '.params.name // empty')
            prompt=$(echo "$line" | jq -r '.params.arguments.prompt // empty')
            model=$(echo "$line" | jq -r '.params.arguments.model // "haiku"')
            timeout=$(echo "$line" | jq -r '.params.arguments.timeout // "660"')
            max_retries=$(echo "$line" | jq -r '.params.arguments.maxRetries // "3"')
            max_turns=$(echo "$line" | jq -r '.params.arguments.maxTurns // empty')
            output_format=$(echo "$line" | jq -r '.params.arguments.outputFormat // "json"')
            json_schema=$(echo "$line" | jq -r '.params.arguments.jsonSchema // empty')
            system_prompt=$(echo "$line" | jq -r '.params.arguments.systemPrompt // empty')
            append_system_prompt=$(echo "$line" | jq -r '.params.arguments.appendSystemPrompt // empty')
            # Arrays: convert to space-separated strings
            allowed_tools=$(echo "$line" | jq -r '.params.arguments.allowedTools // [] | join(" ")')
            disallowed_tools=$(echo "$line" | jq -r '.params.arguments.disallowedTools // [] | join(" ")')
            add_dirs=$(echo "$line" | jq -r '.params.arguments.addDirs // [] | join(" ")')
            verbose=$(echo "$line" | jq -r '.params.arguments.verbose // "false"')

            log "Tool: $tool_name (id=$id)"
            log "Model: $model, Timeout: ${timeout}s, Max retries: $max_retries"
            log "Max turns: ${max_turns:-unlimited}, Output format: $output_format"
            log "Verbose: $verbose"
            log "Prompt: ${prompt:0:50}..."

            # Validate tool name (sync - fast validation before spawning)
            case "$tool_name" in
                claude_generate|claude_edit|claude_refactor|claude_generate_json|claude_edit_json)
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
                _max_turns="$max_turns"
                _output_format="$output_format"
                _json_schema="$json_schema"
                _system_prompt="$system_prompt"
                _append_system_prompt="$append_system_prompt"
                _allowed_tools="$allowed_tools"
                _disallowed_tools="$disallowed_tools"
                _add_dirs="$add_dirs"
                _verbose="$verbose"

                log "[BG $_id] Starting $_tool_name"

                # Execute based on tool type
                case "$_tool_name" in
                    claude_generate|claude_edit|claude_refactor)
                        # Standard response with retry and all options
                        result=$(run_ai_with_retry "$_prompt" "$_model" "$_timeout" "$_max_retries" \
                            "$_max_turns" "$_output_format" "$_json_schema" \
                            "$_system_prompt" "$_append_system_prompt" \
                            "$_allowed_tools" "$_disallowed_tools" "$_add_dirs" "$_verbose")
                        exit_code=$?

                        if [ $exit_code -ne 0 ]; then
                            log "[BG $_id] ERROR: AI execution failed"
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Claude CLI error","data":%s}}' \
                                "$_id" \
                                "$(printf "%s" "$result" | jq -R -s '.')")
                        else
                            log "[BG $_id] Success: Response received"
                            # Extract text result if JSON output
                            local result_text
                            result_text=$(extract_result_text "$result")
                            response=$(printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}]}}' \
                                "$_id" \
                                "$(printf "%s" "$result_text" | jq -R -s '.')")
                        fi
                        ;;

                    claude_generate_json|claude_edit_json)
                        # JSON response with validation and retry
                        json_result=$(run_ai_json_with_retry "$_prompt" "$_model" "$_max_retries" \
                            "$_json_schema" "$_system_prompt" "$_append_system_prompt")
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
