---
name: copilot-bridge
description: Install and configure copilot-bridge + memory-lancedb-pro for OpenClaw. Use when the user wants to set up GitHub Copilot as a local LLM endpoint, configure memory-lancedb-pro with the bridge, or troubleshoot the setup.
trigger: /copilot-bridge
---

# /copilot-bridge

Installs and configures **copilot-bridge** (GitHub Copilot → OpenAI-compatible local proxy) and **memory-lancedb-pro** for OpenClaw.

When the user types `/copilot-bridge`, follow this workflow exactly.

---

## Step 1 — Check prerequisites

Run all checks in parallel:

```bash
# 1. Node.js version (need 22+)
node --version

# 2. Ollama running
curl -s -o /dev/null -w "%{http_code}" http://localhost:11434/api/tags

# 3. nomic-embed-text available
ollama list | grep nomic-embed-text

# 4. OpenClaw credentials exist
ls ~/.openclaw/credentials/github-copilot.token.json
ls ~/.openclaw/agents/main/agent/auth-profiles.json

# 5. OpenClaw version
openclaw --version
```

**If any check fails:**
- Node < 22: `nvm install 22 && nvm use 22`
- Ollama not running: `ollama serve` or `systemctl start ollama`
- nomic-embed-text missing: `ollama pull nomic-embed-text`
- Credentials missing: user must log in to GitHub Copilot in OpenClaw first (`openclaw configure`)
- OpenClaw < 2026.3.22: `openclaw update`

Do not proceed until all checks pass.

---

## Step 2 — Install copilot-bridge

```bash
# Create tools dir if needed
mkdir -p ~/.openclaw/tools

# Download bridge script
curl -fsSL https://raw.githubusercontent.com/bendicado/copilot-ollama-bridge/main/copilot-bridge.js \
  -o ~/.openclaw/tools/copilot-bridge.js

# Test it runs
node ~/.openclaw/tools/copilot-bridge.js &
sleep 3
curl -s http://localhost:11500/v1/models | python3 -c "import sys,json; print('OK:', [m['id'] for m in json.load(sys.stdin)['data']])"
kill %1 2>/dev/null
```

Expected output: `OK: ['github-copilot/gpt-5-mini', 'gpt-5-mini', 'gpt-4o', 'gpt-4o-mini']`

---

## Step 3 — Install as user service (auto-start on boot)

```bash
mkdir -p ~/.config/systemd/user

curl -fsSL https://raw.githubusercontent.com/bendicado/copilot-ollama-bridge/main/systemd/copilot-bridge.service \
  -o ~/.config/systemd/user/copilot-bridge.service

# Replace hardcoded node path with actual path
NODE_PATH=$(which node)
sed -i "s|/home/pi/.nvm/versions/node/v22.22.2/bin/node|$NODE_PATH|g" \
  ~/.config/systemd/user/copilot-bridge.service

# Also replace hardcoded user home if not /home/pi
sed -i "s|/home/pi/.openclaw|$HOME/.openclaw|g" \
  ~/.config/systemd/user/copilot-bridge.service

systemctl --user daemon-reload
systemctl --user enable --now copilot-bridge
systemctl --user status copilot-bridge
```

---

## Step 4 — Verify bridge endpoint

```bash
# Models list
curl -s http://localhost:11500/v1/models | python3 -c "import sys,json; print([m['id'] for m in json.load(sys.stdin)['data']])"

# Live completion test
curl -s http://localhost:11500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"github-copilot/gpt-5-mini","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Reply:', d['choices'][0]['message']['content'])"
```

If the completion fails with 401: the Copilot token needs refresh. The bridge refreshes automatically — wait 5 seconds and retry. If it still fails, the GitHub OAuth token may have expired; the user must re-authenticate via `openclaw configure`.

---

## Step 5 — Install memory-lancedb-pro plugin

```bash
openclaw plugins install memory-lancedb-pro@beta --dangerously-force-unsafe-install 2>&1 \
  | grep -Ev "child_process|dangerous|typebox|node_modules"
```

Expected: plugin installs to `~/.openclaw/extensions/memory-lancedb-pro/`

If you see `plugin already exists`: it's already installed. Skip to Step 6.

### Step 5b — Apply CLI hang fix patch (recommended)

`memory-lancedb-pro@1.1.0-beta.9` has a known issue: `openclaw memory-pro <cmd>` CLI commands print results then **hang indefinitely** because background `setTimeout`/`setInterval` keep the Node event loop alive.

The fix is in this repo at `patches/memory-lancedb-pro-cli-fix.patch`. Apply it:

```bash
# Backup first
cp ~/.openclaw/extensions/memory-lancedb-pro/index.ts \
   ~/.openclaw/extensions/memory-lancedb-pro/index.ts.bak-$(date +%Y%m%d-%H%M%S)

# Download and apply
curl -fsSL https://raw.githubusercontent.com/OneLif2/copilot-ollama-bridge/main/patches/memory-lancedb-pro-cli-fix.patch \
  -o /tmp/mldp-cli-fix.patch
cd ~/.openclaw/extensions/memory-lancedb-pro
patch -p1 < /tmp/mldp-cli-fix.patch

# Clear jiti cache (mandatory after editing plugin .ts files)
rm -rf /tmp/jiti/
```

**Verify the fix:**
```bash
time openclaw memory-pro stats
# Should complete in <2s. Without the patch it hangs forever.
```

> **Re-apply after every plugin update.** `openclaw plugins update memory-lancedb-pro` will overwrite the patched file. Until the fix is merged upstream (https://github.com/CortexReach/memory-lancedb-pro), keep the patch handy.

---

## Step 6 — Apply config to openclaw.json

Read the current config first, then do a surgical merge — never overwrite the whole file.

```bash
# Show current plugins section
openclaw config get plugins.entries.memory-lancedb-pro 2>/dev/null || echo "not yet configured"
openclaw config get plugins.slots 2>/dev/null
```

Then apply:

```bash
openclaw config set plugins.slots.memory memory-lancedb-pro

openclaw config set plugins.entries.memory-lancedb-pro '{
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
}'
```

---

## Step 7 — Validate, restart, verify

```bash
# 1. Validate config schema
openclaw config validate

# 2. Restart gateway
openclaw gateway restart

# 3. Confirm plugin loaded
openclaw plugins info memory-lancedb-pro 2>&1 | grep -E "smart extraction|plugin registered|enabled"

# 4. Stats (should show 0 memories on fresh install)
openclaw memory-pro stats
```

**Expected logs:**
```
memory-lancedb-pro: smart extraction enabled (LLM model: github-copilot/gpt-5-mini, noise bank: ON)
memory-lancedb-pro@1.1.0-beta.9: plugin registered (db: ~/.openclaw/memory/lancedb-pro, model: nomic-embed-text, smartExtraction: ON)
```

---

## Fallback: use gemma3:4b if bridge is unavailable

If the copilot-bridge is not running (e.g. Copilot token permanently expired), switch to local Ollama:

```bash
openclaw config set plugins.entries.memory-lancedb-pro.config.llm '{
  "apiKey": "ollama",
  "model": "gemma3:4b",
  "baseURL": "http://localhost:11434/v1"
}'
openclaw config set plugins.entries.memory-lancedb-pro.config.smartExtraction false
openclaw gateway restart
```

> Set `smartExtraction: false` with gemma3:4b — it often produces malformed JSON for structured extraction tasks.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `memory-lancedb-pro: plugin not found` | `openclaw plugins install memory-lancedb-pro@beta --dangerously-force-unsafe-install` |
| Bridge returns 401 | Token expired — restart bridge: `systemctl --user restart copilot-bridge` |
| Bridge returns 401 after restart | OAuth token revoked — re-auth: `openclaw configure` |
| `embedding: must have required property 'embedding'` | Config not applied — redo Step 6 |
| `baseUrl` schema error | Use `baseURL` (capital URL), not `baseUrl` |
| `autoRecall` not injecting memories | Default is `false` — set `"autoRecall": true` explicitly |
| No memories after conversation | Need `extractMinMessages: 2` turns before extraction fires |
| jiti cache error after plugin update | `rm -rf /tmp/jiti/ && openclaw gateway restart` |

---

## Health Check

Run this after setup (or any time you suspect the pipeline is broken):

```bash
bash ~/.openclaw/tools/scripts/check-memory.sh
# or if installed from the repo:
bash ~/path/to/copilot-ollama-bridge/scripts/check-memory.sh
```

What it checks (no `curl` required — uses `node` for HTTP tests):

| Check | How |
|---|---|
| Bridge service active | `systemctl --user is-active` |
| LLM endpoint replies | HTTP POST to `/v1/chat/completions` |
| Ollama embedding returns vectors | HTTP POST to `/v1/embeddings` |
| Plugin configured in `openclaw.json` | Direct JSON parse (avoids CLI hang) |
| LanceDB files present | `~/.openclaw/memory/lancedb-pro/` |
| Embedding pipeline | Two parallel embed calls |
| autoRecall firing | `openclaw logs --plain` grep |

**Known limitation:** `openclaw memory-pro stats/search` hang in non-TTY
contexts (background `setInterval` keeps Node alive — upstream bug in
`memory-lancedb-pro@1.1.0-beta.9`). The script works around this by reading
`openclaw.json` and the LanceDB directory directly instead of using the CLI.
Apply `patches/memory-lancedb-pro-cli-fix.patch` to fix the CLI if needed.

**`usage_limit_reached` warning:**
If the bridge LLM check returns a usage-limit warning, smart extraction calls
will fail until the quota resets (the `resets_at` timestamp is shown). Embedding
and recall still work — only new memory extraction is affected.

Environment overrides:
```bash
CODEX_BRIDGE_MODEL=openai-codex/gpt-5.5 \
MEMORY_EMBED_MODEL=mxbai-embed-large \
bash scripts/check-memory.sh
```