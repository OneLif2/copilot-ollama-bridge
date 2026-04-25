# Patches

## `memory-lancedb-pro-cli-fix.patch`

**Target:** `memory-lancedb-pro@1.1.0-beta.9` (CortexReach/memory-lancedb-pro)
**Issue:** `openclaw memory-pro <subcommand>` CLI commands hang forever after completing — they print results then never exit.
**Root cause:** Plugin's `register()` starts background `setTimeout` / `setInterval` (noise bank init, startup checks, periodic backup) without `.unref()`, so they keep Node's event loop alive even when the plugin is loaded only for a one-shot CLI call.

### What the patch changes

1. Adds CLI invocation detection:
   ```js
   const isMemoryCliInvocation = process.argv.some((arg) => arg === "memory-pro");
   ```
2. Skips `noiseBank.init(...)` when running CLI commands.
3. Adds an early `return` after CLI registration so background work never starts.
4. Wraps remaining timers with `.unref?.()` so they don't block process exit:
   - `startupChecksTimer`
   - `legacyUpgradeTimer`
   - `initialBackupTimer`
   - `backupTimer` (interval)

Net effect: `openclaw memory-pro stats / list / search / ...` now exit cleanly in <1s. Plugin loaded by the gateway (long-running) is unchanged in behavior — timers still fire because the gateway doesn't pass `memory-pro` in argv.

### How to apply

```bash
# Backup first
cp ~/.openclaw/extensions/memory-lancedb-pro/index.ts \
   ~/.openclaw/extensions/memory-lancedb-pro/index.ts.bak-$(date +%Y%m%d-%H%M%S)

# Apply
cd ~/.openclaw/extensions/memory-lancedb-pro
patch -p1 < /path/to/memory-lancedb-pro-cli-fix.patch

# Clear jiti cache and restart
rm -rf /tmp/jiti/
openclaw gateway restart
```

### Verify

```bash
# Should exit immediately (not hang)
time openclaw memory-pro stats
```

Expected: completes in under 2 seconds with `real    0m1.x`s.

### Re-apply after plugin update

This patch will be **lost** when you run `openclaw plugins update memory-lancedb-pro`. Re-apply after every update until the fix is merged upstream.

Upstream PR target: https://github.com/CortexReach/memory-lancedb-pro

### Generating a fresh patch from your own edits

If you make further changes:

```bash
diff -u ~/.openclaw/extensions/memory-lancedb-pro/index.ts.bak-YYYYMMDD-HHMMSS \
        ~/.openclaw/extensions/memory-lancedb-pro/index.ts \
  > patches/memory-lancedb-pro-cli-fix.patch

# Make paths relative for portability
sed -i 's|.*\.bak-[0-9-]*|a/index.ts|; s|.*/memory-lancedb-pro/index.ts|b/index.ts|' \
  patches/memory-lancedb-pro-cli-fix.patch
```
