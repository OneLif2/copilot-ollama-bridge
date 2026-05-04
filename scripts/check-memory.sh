#!/usr/bin/env bash
# check-memory.sh — health check for memory-lancedb-pro + LLM bridge
#
# Tests (in order):
#   1. bridge systemd service is active
#   2. bridge LLM endpoint responds correctly
#   3. Ollama embedding endpoint returns correct dimensions
#   4. memory-lancedb-pro plugin is registered
#   5. hybrid retrieval (search) returns results
#   6. autoRecall injection is active in live logs
#
# No curl required — uses node for HTTP checks.
#
# Usage:
#   bash scripts/check-memory.sh
#   CODEX_BRIDGE_MODEL=openai-codex/gpt-5.5 bash scripts/check-memory.sh
#
# Environment overrides:
#   CODEX_BRIDGE_HOST       default: 127.0.0.1
#   CODEX_BRIDGE_PORT       default: 11540
#   CODEX_BRIDGE_MODEL      default: openai-codex/gpt-5.4-mini
#   OLLAMA_BASE_URL         default: http://localhost:11434
#   MEMORY_EMBED_MODEL      default: nomic-embed-text
#   MEMORY_SCOPE            default: agent:main

set -uo pipefail

BRIDGE_HOST="${CODEX_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${CODEX_BRIDGE_PORT:-11540}"
BRIDGE_MODEL="${CODEX_BRIDGE_MODEL:-openai-codex/gpt-5.4-mini}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
EMBED_MODEL="${MEMORY_EMBED_MODEL:-nomic-embed-text}"
MEMORY_SCOPE="${MEMORY_SCOPE:-agent:main}"

PASS=0
FAIL=0
WARN=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "${GREEN}✓${RESET} %s\n" "$*";   ((PASS++))  || true; }
fail() { printf "${RED}✗${RESET} %s\n" "$*" >&2; ((FAIL++))  || true; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*";  ((WARN++))  || true; }
info() { printf "  %s\n" "$*"; }
sep()  { printf "${BOLD}── %s${RESET}\n" "$*"; }

# ── 1. Bridge service ─────────────────────────────────────────────────────────
sep "Bridge service"
ACTIVE_SERVICE=""
for svc in codex-ollama-bridge copilot-bridge; do
  if systemctl --user is-active --quiet "${svc}" 2>/dev/null; then
    ACTIVE_SERVICE="$svc"
    break
  fi
done

if [[ -n "$ACTIVE_SERVICE" ]]; then
  ok "${ACTIVE_SERVICE}.service is active"
else
  fail "no bridge service is active (checked: codex-ollama-bridge, copilot-bridge)"
fi

# ── 2. Bridge LLM endpoint ────────────────────────────────────────────────────
sep "Bridge LLM  →  http://${BRIDGE_HOST}:${BRIDGE_PORT}/v1"
LLM_RESULT=$(node -e "
const http = require('http');
const body = JSON.stringify({
  model: '${BRIDGE_MODEL}',
  messages: [{role:'user', content:'say ok'}],
  stream: false
});
const req = http.request({
  hostname: '${BRIDGE_HOST}', port: ${BRIDGE_PORT},
  path: '/v1/chat/completions', method: 'POST',
  headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
}, res => {
  let d = '';
  res.on('data', c => d += c);
  res.on('end', () => {
    try {
      const o = JSON.parse(d);
      if (o.error) {
        const msg = o.error.message || JSON.stringify(o.error);
        process.stdout.write('ERR:' + msg);
        process.exit(1);
      }
      const reply = o.choices?.[0]?.message?.content?.trim() || '(empty)';
      process.stdout.write('OK:' + reply);
    } catch(e) {
      process.stdout.write('ERR:parse:' + e.message);
      process.exit(1);
    }
  });
});
req.on('error', e => { process.stdout.write('ERR:' + e.message); process.exit(1); });
req.write(body);
req.end();
" 2>/dev/null || echo "ERR:node execution failed")

if [[ "$LLM_RESULT" == OK:* ]]; then
  ok "model ${BRIDGE_MODEL} → \"${LLM_RESULT#OK:}\""
else
  MSG="${LLM_RESULT#ERR:}"
  if echo "$MSG" | grep -q "usage_limit_reached"; then
    RESET_IN=$(echo "$MSG" | node -e "process.stdin.resume();let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{const o=JSON.parse(d);const s=o?.resets_in_seconds;if(s){const m=Math.ceil(s/60);process.stdout.write(m+' min');}else{process.stdout.write('unknown');}}catch{process.stdout.write('unknown');}})" 2>/dev/null || echo "unknown")
    warn "Codex usage limit reached — resets in ~${RESET_IN} (extraction will fail until reset)"
  else
    fail "LLM: ${MSG}"
  fi
fi

# ── 3. Ollama embedding ───────────────────────────────────────────────────────
sep "Ollama embedding  →  ${OLLAMA_BASE_URL}"
OLLAMA_URL_HOST=$(node -e "const u=new URL('${OLLAMA_BASE_URL}'); process.stdout.write(u.hostname);" 2>/dev/null || echo "localhost")
OLLAMA_URL_PORT=$(node -e "const u=new URL('${OLLAMA_BASE_URL}'); process.stdout.write(u.port||'11434');" 2>/dev/null || echo "11434")

EMBED_RESULT=$(node -e "
const http = require('http');
const body = JSON.stringify({model: '${EMBED_MODEL}', input: 'memory health check'});
const req = http.request({
  hostname: '${OLLAMA_URL_HOST}', port: ${OLLAMA_URL_PORT},
  path: '/v1/embeddings', method: 'POST',
  headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
}, res => {
  let d = '';
  res.on('data', c => d += c);
  res.on('end', () => {
    try {
      const o = JSON.parse(d);
      const emb = o.data?.[0]?.embedding || o.embedding;
      if (!Array.isArray(emb)) {
        process.stdout.write('ERR:unexpected response — ' + d.slice(0, 120));
        process.exit(1);
      }
      process.stdout.write('OK:' + emb.length);
    } catch(e) {
      process.stdout.write('ERR:parse:' + e.message);
      process.exit(1);
    }
  });
});
req.on('error', e => { process.stdout.write('ERR:' + e.message); process.exit(1); });
req.write(body);
req.end();
" 2>/dev/null || echo "ERR:node execution failed")

if [[ "$EMBED_RESULT" == OK:* ]]; then
  DIMS="${EMBED_RESULT#OK:}"
  ok "${EMBED_MODEL}  →  ${DIMS}-dim"
  if [[ "$DIMS" -lt 512 ]]; then
    warn "Low embedding dimensions (${DIMS}) — consider mxbai-embed-large (1024-dim) for better retrieval quality"
  fi
else
  fail "embedding: ${EMBED_RESULT#ERR:}"
  info "fix: ollama pull ${EMBED_MODEL} && systemctl start ollama"
fi

# ── 4. Plugin registration ────────────────────────────────────────────────────
# NOTE: openclaw memory-pro CLI hangs in non-TTY contexts (known bug: background
# setInterval keeps Node event loop alive). We check the config + DB directly.
sep "memory-lancedb-pro plugin"
OPENCLAW_CFG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
PLUGIN_CHECK=$(node -e "
try {
  const fs = require('fs');
  const cfg = JSON.parse(fs.readFileSync('${OPENCLAW_CFG}', 'utf8'));
  const entry = cfg?.plugins?.entries?.['memory-lancedb-pro'];
  const slot  = cfg?.plugins?.slots?.memory;
  const errs  = [];
  if (!cfg?.plugins?.allow?.includes('memory-lancedb-pro')) errs.push('not in plugins.allow');
  if (slot !== 'memory-lancedb-pro') errs.push('plugins.slots.memory = ' + slot);
  if (!entry?.enabled) errs.push('enabled = false');
  if (!entry?.config?.llm?.baseURL) errs.push('llm.baseURL missing');
  if (!entry?.config?.embedding?.model) errs.push('embedding.model missing');
  if (errs.length) { process.stdout.write('ERR:' + errs.join('; ')); process.exit(1); }
  const c = entry.config;
  const out = [
    'OK',
    'llm=' + c.llm.model + '@' + c.llm.baseURL,
    'embed=' + c.embedding.model,
    'autoCapture=' + c.autoCapture,
    'autoRecall=' + c.autoRecall,
    'smartExtraction=' + c.smartExtraction,
  ].join('|');
  process.stdout.write(out);
} catch(e) { process.stdout.write('ERR:' + e.message); process.exit(1); }
" 2>/dev/null || echo "ERR:node failed")

if [[ "$PLUGIN_CHECK" == OK* ]]; then
  ok "plugin configured in openclaw.json"
  echo "$PLUGIN_CHECK" | tr '|' '\n' | tail -n +2 | while IFS= read -r kv; do info "$kv"; done

  if echo "$PLUGIN_CHECK" | grep -q "smartExtraction=true"; then
    ok "smart extraction enabled"
  else
    warn "smart extraction is disabled (set smartExtraction: true for LLM-powered extraction)"
  fi
else
  fail "plugin config: ${PLUGIN_CHECK#ERR:}"
fi

# Check LanceDB files exist
LANCEDB_DIR="${HOME}/.openclaw/memory/lancedb-pro"
if [[ -d "$LANCEDB_DIR" ]]; then
  DB_SIZE=$(du -sh "$LANCEDB_DIR" 2>/dev/null | awk '{print $1}')
  ok "LanceDB present  (${LANCEDB_DIR}, ${DB_SIZE})"
else
  warn "LanceDB dir not found — will be created on first memory store"
fi

# ── 5. Hybrid retrieval ───────────────────────────────────────────────────────
# openclaw memory-pro search also hangs in non-TTY; test embedding directly instead.
sep "Embedding / retrieval pipeline"
EMBED_CHECK=$(node -e "
const http = require('http');
const OLLAMA_HOST = '${OLLAMA_URL_HOST}';
const OLLAMA_PORT = ${OLLAMA_URL_PORT};
const queries = ['WhatsApp gateway', 'memory recall test'];
let done = 0;
queries.forEach(q => {
  const body = JSON.stringify({model: '${EMBED_MODEL}', input: q});
  const req = http.request({
    hostname: OLLAMA_HOST, port: OLLAMA_PORT,
    path: '/v1/embeddings', method: 'POST',
    headers: {'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}
  }, res => {
    let d = ''; res.on('data', c => d += c);
    res.on('end', () => {
      try {
        const o = JSON.parse(d);
        const emb = o.data?.[0]?.embedding;
        if (!Array.isArray(emb)) { process.stdout.write('ERR:no embedding for: ' + q); process.exit(1); }
        if (++done === queries.length) process.stdout.write('OK:' + emb.length + '-dim x' + queries.length);
      } catch(e) { process.stdout.write('ERR:' + e.message); process.exit(1); }
    });
  });
  req.on('error', e => { process.stdout.write('ERR:' + e.message); process.exit(1); });
  req.write(body); req.end();
});
" 2>/dev/null || echo "ERR:node failed")

if [[ "$EMBED_CHECK" == OK:* ]]; then
  ok "embed pipeline: ${EMBED_CHECK#OK:} per query"
else
  fail "embed pipeline: ${EMBED_CHECK#ERR:}"
fi

# ── 6. autoRecall in live logs ────────────────────────────────────────────────
sep "autoRecall injection"
INJECT=$(openclaw logs --plain 2>/dev/null | grep "injecting.*memories into context" | tail -1)
if [[ -n "$INJECT" ]]; then
  INJECT_DETAIL=$(echo "$INJECT" | grep -oE 'injecting [0-9]+ memor[^ ]+.*' || echo "$INJECT")
  ok "autoRecall active — last seen: ${INJECT_DETAIL}"
else
  warn "no autoRecall log entry yet (fires during agent conversations — not a problem on fresh setup)"
fi

# ── mdMirror warning ──────────────────────────────────────────────────────────
if echo "$PLUGIN_CHECK" | grep -q "autoRecall=false"; then
  warn "autoRecall is false — memories will not be injected into context automatically"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}────────────────────────────────────────────${RESET}\n"
printf "  ${GREEN}PASS${RESET}: %-3s  ${YELLOW}WARN${RESET}: %-3s  ${RED}FAIL${RESET}: %s\n" "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf "  ${RED}${BOLD}RESULT: DEGRADED${RESET}\n"
  exit 1
elif (( WARN > 0 )); then
  printf "  ${YELLOW}${BOLD}RESULT: OK (with warnings)${RESET}\n"
else
  printf "  ${GREEN}${BOLD}RESULT: OK${RESET}\n"
fi
