# mcp-claude-shell
A lightweight MCP server that exposes local Claude Code CLI commands as structured tools with retry, timeout control, and JSON-validated responses.

Here is a clean, professional, GitHub-ready English README.md rewritten specifically for your MCP server and the mcp.json you provided.

If you want a more fancy “GitHub-premium style” version (icons, shields, badges, banners), I can generate that too.

⸻

📘 README.md (English Version)

# Claude Shell MCP Server

This project provides a lightweight **Shell-based MCP (Model Context Protocol) server**  
that exposes the local **Claude Code CLI** as structured MCP tools.

With this server, any MCP-compatible client (Cursor, Claude Desktop, VSCode MCP, custom agents, etc.)  
can call the local `claude` command as if it were a remote AI API — but with the speed, privacy, and flexibility of local execution.

---

## ✨ Features

### ✔ Multiple High-Level MCP Tools
The server exposes five AI-powered tools:

- `claude.generate` — Generate text or code  
- `claude.edit` — Edit existing content  
- `claude.refactor` — Refactor code  
- `claude.generate.json` — Generate **validated JSON** with auto-retry  
- `claude.edit.json` — Edit JSON structures with validation and retry  

---

### ✔ Local Claude CLI Integration
All tools ultimately call:

claude -p “”

with optional model selection, timeouts, and retry logic.

---

### ✔ Automatic Retry & Timeout Handling
Supports:

- `maxRetries`
- `timeout` (per call)

This makes the system resilient to:

- Empty responses  
- CLI execution errors  
- Invalid JSON  
- Long-running operations  

---

### ✔ JSON Schema Enforcement
`claude.generate.json` and `claude.edit.json` ensure the model returns  
**valid JSON**, retrying automatically when structure is incorrect.

Perfect for:

- Agent workflows  
- Automated refactoring  
- Config generation  
- Structured pipelines  

---

## 📁 Project Structure

.
├── mcp.json            # MCP server manifest
└── mcp-claude.sh       # Shell script: handles MCP I/O & Claude CLI calls

---

## 🚀 Getting Started

### 1. Install the Claude CLI

macOS:
```sh
  brew install anthropic
```
Test:

```sh
  claude -p "hello"
```

⸻

2. Make the server executable

```sh
  chmod +x ./mcp-claude.sh
```

⸻

3. Add this server to your MCP client

Place this directory into your MCP servers folder (varies by client):

Client	Path
Cursor	~/.cursor/mcp/
Claude Desktop	~/Library/Application Support/Claude/mcp/servers/
VSCode	Through the MCP extension

The client will automatically read:

mcp.json

and load the tools.

⸻

🔧 MCP Tools Overview

### 1. claude.generate

General-purpose generation (text, code, documentation).

Input schema:

{
  "prompt": "string",
  "model": "haiku | sonnet | opus",
  "timeout": 660,
  "maxRetries": 3
}


⸻

### 2. claude.edit

Edit or transform existing text/code.

⸻

### 3. claude.refactor

Refactor codebases or files.

⸻

### 4. claude.generate.json

Generate strict JSON with validation and automatic retry.

Useful for:
	•	Agents
	•	Workflows
	•	Data extraction
	•	Structured output generation

⸻

### 5. claude.edit.json

Edit JSON while ensuring the result remains valid.

⸻

📄 About mcp.json

The included manifest declares:
	•	Server name, version, description
	•	Startup command (./mcp-claude.sh)
	•	Five tools with explicit JSON schemas
	•	Model options (haiku, sonnet, opus)
	•	Retry & timeout fields

This allows MCP clients to introspect your server and use it without configuration.

⸻

🛠 Extending the Server

Possible extensions include:
	•	Streaming output
	•	Unified CLI router (Claude + OpenAI + Gemini + Groq)
	•	Enhanced error reporting
	•	Custom logging
	•	Shared server configuration file
	•	Additional specialized tools

If you need these, feel free to request fully generated implementations.

⸻

📜 License

MIT License

⸻

🙌 Contributions

PRs and suggestions are welcome!
Feel free to open issues for tool improvements or new features.
