# copilot-ollama-bridge

A lightweight local HTTP proxy that exposes GitHub Copilot (OAuth-authenticated) as an **OpenAI-compatible REST endpoint** at `http://localhost:11500/v1`.

This lets you use `github-copilot/gpt-5-mini` (and other Copilot models) in any tool that accepts an OpenAI-compatible `baseURL` — including **memory-lancedb-pro**, LangChain, and other local AI tooling — without needing a paid OpenAI API key.

## Architecture

```
memory-lancedb-pro (Smart Extraction)
        │
        ▼
http://localhost:11500/v1/chat/completions   ← copilot-bridge (this repo)
        │
        ▼
https://api.individual.githubcopilot.com    ← GitHub Copilot REST API
        │
        ▼
github-copilot/gpt-5-mini  (OAuth via OpenClaw credentials)
```

Embeddings use **Ollama** locally (`nomic-embed-text`) — no API key required.

## Requirements

- [OpenClaw](https://openclaw.ai) installed and configured with GitHub Copilot OAuth
- Node.js 22+
- Ollama with `nomic-embed-text` pulled

## Quick Start

### 1. Install the bridge

```bash
git clone https://github.com/bendicado/copilot-ollama-bridge
cd copilot-ollama-bridge
node copilot-bridge.js
```

Or install as a background service (Linux):

```bash
cp copilot-bridge.js ~/.openclaw/tools/copilot-bridge.js
cp systemd/copilot-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now copilot-bridge
```

### 2. Verify it works

```bash
# List available models
curl http://localhost:11500/v1/models

# Test a completion
curl http://localhost:11500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"github-copilot/gpt-5-mini","messages":[{"role":"user","content":"say hi"}],"max_tokens":20}'
```

### 3. Pull Ollama embedding model

```bash
ollama pull nomic-embed-text
```

## Configure memory-lancedb-pro

### Step 1 — Install the plugin

```bash
openclaw plugins install memory-lancedb-pro@beta --dangerously-force-unsafe-install
```

> The `--dangerously-force-unsafe-install` flag is required because the plugin uses `child_process` internally (for migration/upgrade commands). This is a false positive from OpenClaw's security scanner.

### Step 2 — Add to `openclaw.json`

Add the following to your `~/.openclaw/openclaw.json` inside the `plugins` section:

```json
{
  "plugins": {
    "slots": { "memory": "memory-lancedb-pro" },
    "entries": {
      "memory-lancedb-pro": {
        "enabled": true,
        "config": {
          "embedding": {
            "apiKey": "ollama",
            "model": "nomic-embed-text",
            "baseURL": "http://localhost:11434/v1",
            "dimensions": 768
          },
          "autoCapture": true,
          "autoRecall": true,
          "captureAssistant": false,
          "smartExtraction": true,
          "extractMinMessages": 2,
          "extractMaxChars": 4000,
          "llm": {
            "apiKey": "copilot-bridge",
            "model": "github-copilot/gpt-5-mini",
            "baseURL": "http://localhost:11500/v1"
          },
          "retrieval": {
            "mode": "hybrid",
            "vectorWeight": 0.7,
            "bm25Weight": 0.3,
            "filterNoise": true,
            "minScore": 0.25,
            "hardMinScore": 0.28
          },
          "sessionStrategy": "none"
        }
      }
    }
  }
}
```

### Step 3 — Restart gateway and verify

```bash
openclaw gateway restart
openclaw config validate
openclaw plugins info memory-lancedb-pro
openclaw memory-pro stats
```

Expected logs:

```
memory-lancedb-pro: smart extraction enabled
memory-lancedb-pro@1.1.0-beta.9: plugin registered
```

### Step 4 — Smoke test

```bash
# Should show 0 memories on fresh install
openclaw memory-pro stats

# Store a test memory via CLI
# Then have a 2-turn conversation — autoCapture will trigger
```

## Supported Models

| Model name | Notes |
|---|---|
| `github-copilot/gpt-5-mini` | Default, fast, good JSON output |
| `gpt-5-mini` | Alias for above |
| `gpt-4o` | Higher quality, slower |
| `gpt-4o-mini` | Fallback |

## Token Refresh

The bridge reads the cached Copilot session token from:

```
~/.openclaw/credentials/github-copilot.token.json
```

When the token expires (~30 min TTL), it automatically refreshes using the GitHub OAuth token stored by OpenClaw in:

```
~/.openclaw/agents/main/agent/auth-profiles.json
```

No manual token management required.

## Alternative: Use gemma3:4b as fallback LLM

If the bridge is not running or Copilot is unavailable, fall back to local Ollama:

```json
"llm": {
  "apiKey": "ollama",
  "model": "gemma3:4b",
  "baseURL": "http://localhost:11434/v1"
}
```

> Note: Set `"smartExtraction": false` if `gemma3:4b` produces malformed JSON output.

## Hardware Notes (Jetson Xavier NX / aarch64)

- `@lancedb/lancedb` supports `arm64` — no AVX required
- Tested on Jetson Xavier NX 8 GB (Ubuntu 20.04, aarch64)
- Gemma 4 models (all variants) require 7+ GB RAM — **not compatible** with 8 GB Jetson
- Safe model size limit on 8 GB Jetson: ~3.5 GB (use `gemma3:4b` or `qwen3:4b`)

## License

MIT
