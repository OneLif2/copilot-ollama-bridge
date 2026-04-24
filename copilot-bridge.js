#!/usr/bin/env node
/**
 * copilot-bridge.js
 * OpenAI-compatible HTTP proxy for GitHub Copilot via OpenClaw credentials.
 * Exposes http://localhost:11500/v1/chat/completions (and /v1/models, /api/chat for Ollama compat).
 */

import http from "http";
import https from "https";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const PORT = process.env.COPILOT_BRIDGE_PORT || 11500;
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(process.env.HOME, ".openclaw");
const TOKEN_FILE = path.join(OPENCLAW_HOME, "credentials", "github-copilot.token.json");
const AUTH_PROFILES = path.join(OPENCLAW_HOME, "agents", "main", "agent", "auth-profiles.json");
const COPILOT_API = "api.individual.githubcopilot.com";
const REFRESH_URL = "https://api.github.com/copilot_internal/v2/token";

// ── Token management ──────────────────────────────────────────────────────────

function readTokenFile() {
  try {
    return JSON.parse(fs.readFileSync(TOKEN_FILE, "utf8"));
  } catch {
    return null;
  }
}

function readGithubOAuthToken() {
  try {
    const profiles = JSON.parse(fs.readFileSync(AUTH_PROFILES, "utf8"));
    return profiles?.profiles?.["github-copilot:github"]?.token || null;
  } catch {
    return null;
  }
}

function writeTokenFile(data) {
  fs.writeFileSync(TOKEN_FILE, JSON.stringify(data, null, 2));
}

async function fetchNewCopilotToken(oauthToken) {
  return new Promise((resolve, reject) => {
    const req = https.request(REFRESH_URL, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${oauthToken}`,
        "Editor-Version": "vscode/1.99.0",
        "Editor-Plugin-Version": "copilot/1.0.0",
        "User-Agent": "GitHubCopilotChat/0.22.4",
      },
    }, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        if (res.statusCode !== 200) return reject(new Error(`Token refresh failed: ${res.statusCode} ${body}`));
        try {
          const data = JSON.parse(body);
          resolve(data.token);
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on("error", reject);
    req.end();
  });
}

async function getCopilotToken() {
  const cached = readTokenFile();
  if (cached?.token && cached.expiresAt > Date.now() + 60_000) {
    return cached.token;
  }
  console.log("[bridge] Refreshing Copilot token...");
  const oauthToken = readGithubOAuthToken();
  if (!oauthToken) throw new Error("No GitHub OAuth token found in auth-profiles.json");
  const newToken = await fetchNewCopilotToken(oauthToken);
  writeTokenFile({ token: newToken, expiresAt: Date.now() + 25 * 60 * 1000, updatedAt: new Date().toISOString() });
  console.log("[bridge] Token refreshed OK");
  return newToken;
}

// ── Copilot API proxy ─────────────────────────────────────────────────────────

async function callCopilot(body, stream = false) {
  const token = await getCopilotToken();
  const payload = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: COPILOT_API,
      path: "/chat/completions",
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(payload),
        "Editor-Version": "vscode/1.99.0",
        "Copilot-Integration-Id": "vscode-chat",
        "User-Agent": "GitHubCopilotChat/0.22.4",
      },
    }, resolve);
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// ── HTTP server ───────────────────────────────────────────────────────────────

function send(res, status, body) {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
  res.end(payload);
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      try { resolve(data ? JSON.parse(data) : {}); }
      catch (e) { reject(e); }
    });
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") {
    res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "*" });
    return res.end();
  }

  const url = req.url.split("?")[0];

  // ── GET /v1/models or /api/tags (Ollama compat) ──
  if (req.method === "GET" && (url === "/v1/models" || url === "/api/tags")) {
    const models = [
      { id: "github-copilot/gpt-5-mini", object: "model", created: 1700000000, owned_by: "github-copilot" },
      { id: "gpt-5-mini",                object: "model", created: 1700000000, owned_by: "github-copilot" },
      { id: "gpt-4o",                    object: "model", created: 1700000000, owned_by: "github-copilot" },
      { id: "gpt-4o-mini",               object: "model", created: 1700000000, owned_by: "github-copilot" },
    ];
    if (url === "/api/tags") {
      return send(res, 200, { models: models.map(m => ({ name: m.id, modified_at: new Date().toISOString(), size: 0 })) });
    }
    return send(res, 200, { object: "list", data: models });
  }

  // ── POST /v1/chat/completions ──
  if (req.method === "POST" && (url === "/v1/chat/completions" || url === "/api/chat")) {
    let body;
    try { body = await parseBody(req); }
    catch { return send(res, 400, { error: "Invalid JSON" }); }

    // Normalize Ollama /api/chat format → OpenAI format
    if (url === "/api/chat" && body.messages && !body.model) {
      body.model = "gpt-5-mini";
    }

    // Map "github-copilot/gpt-5-mini" → "gpt-5-mini" for Copilot API
    if (body.model?.startsWith("github-copilot/")) {
      body.model = body.model.replace("github-copilot/", "");
    }

    const stream = body.stream === true;

    try {
      const upstream = await callCopilot(body, stream);
      res.writeHead(upstream.statusCode, {
        "Content-Type": stream ? "text/event-stream" : "application/json",
        "Access-Control-Allow-Origin": "*",
      });
      upstream.pipe(res);
    } catch (err) {
      console.error("[bridge] Error:", err.message);
      send(res, 500, { error: { message: err.message, type: "bridge_error" } });
    }
    return;
  }

  // ── POST /api/generate (Ollama generate compat) ──
  if (req.method === "POST" && url === "/api/generate") {
    let body;
    try { body = await parseBody(req); }
    catch { return send(res, 400, { error: "Invalid JSON" }); }

    const chatBody = {
      model: (body.model || "gpt-5-mini").replace("github-copilot/", ""),
      messages: [{ role: "user", content: body.prompt || "" }],
      stream: false,
    };
    if (body.system) chatBody.messages.unshift({ role: "system", content: body.system });

    try {
      const upstream = await callCopilot(chatBody);
      let raw = "";
      upstream.on("data", (c) => (raw += c));
      upstream.on("end", () => {
        try {
          const d = JSON.parse(raw);
          const text = d.choices?.[0]?.message?.content || "";
          send(res, 200, { model: body.model, response: text, done: true });
        } catch {
          send(res, 500, { error: "Parse error" });
        }
      });
    } catch (err) {
      send(res, 500, { error: err.message });
    }
    return;
  }

  send(res, 404, { error: "Not found" });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[copilot-bridge] Listening on http://localhost:${PORT}`);
  console.log(`  OpenAI endpoint : http://localhost:${PORT}/v1/chat/completions`);
  console.log(`  Ollama compat   : http://localhost:${PORT}/api/chat`);
  console.log(`  Model list      : http://localhost:${PORT}/v1/models`);
  console.log(`  Default model   : github-copilot/gpt-5-mini`);
});

server.on("error", (e) => {
  if (e.code === "EADDRINUSE") {
    console.error(`[copilot-bridge] Port ${PORT} already in use. Kill existing process or set COPILOT_BRIDGE_PORT.`);
  } else {
    console.error("[copilot-bridge]", e.message);
  }
  process.exit(1);
});
