# Hermes Discord Status

A private, local-only live status bar for Hermes Agent in Discord.

It combines two components:

- `bridge/` — a standalone Hermes external plugin. It exposes a minimal authenticated status API on `127.0.0.1`.
- `vencord-userplugin/hermesStatus/` — a Vencord userplugin. Selecting a parent channel is an explicit scope selector for Hermes-created child threads under it; each inherited child thread still polls the bridge with its own exact thread ID. Selecting a specific thread enables that thread directly. Selected parent channels hide the bar by default unless `showInParentChannels` is enabled.

## What it shows

- active model
- current context used / maximum, 10-segment gauge, and percentage
- cumulative total processed tokens
- compression count and active subagent count
- current-turn and session timers
- bridge update freshness and YOLO indicator when active
- active tool and tool-call count
- connected, stale, disconnected, or error state

It does **not** add a footer to Discord messages. It does **not** send status data to any remote service.

`Total processed` is memory-only for the current live Hermes session/thread. It starts as unknown and displays as `Total --` after a gateway restart or historic route fallback, because the bridge intentionally keeps no ledger, database, file, lock, tombstone, replay state, or other persistent accounting. After a new authoritative Hermes session starts, the total becomes numeric only when the bridge accepts a matching `pre_api_request` / `post_api_request` pair for the same `api_request_id` and `turn_id`. It adds the canonical `usage.total_tokens` from each accepted successful model API request, which covers the provider-processed prompt/input plus output for that request. It is distinct from current context, which remains the latest request's context-window usage. Cached input, reasoning, or other token detail buckets are not added separately, because the canonical total already accounts for the request without double-counting. Child subagent session usage is not included in the parent conversation counter. If request identity is missing, a completion arrives without a matching current pre-request, the canonical total is missing/invalid, a matching request errors, or the safe wire integer range would overflow, the live lifecycle's total returns to unknown rather than showing a misleading undercount.

## Privacy model

- The bridge binds exclusively to `127.0.0.1`.
- Requests require a bearer token.
- The Vencord plugin only accepts a loopback HTTP bridge URL.
- The token is stored in local Vencord IndexedDB, not in Vencord's synchronised plugin settings.
- The bridge returns no prompts, assistant responses, tool arguments, or tool results.
- A selected parent channel is an explicit scope for Hermes-created child threads beneath it. The Vencord plugin decides that inheritance locally, then polls the bridge with the child thread's exact ID.
- The bar is hidden in a selected parent channel by default (`showInParentChannels=false`). Enable `showInParentChannels` to display it in the selected parent channel as well.
- A specific thread can also be selected directly to enable the bar in that thread.
- The bridge does not expand visibility by itself; it only resolves the channel or thread ID that the Vencord plugin explicitly requests.

## Installation

Use `install.ps1` from Windows PowerShell. Hermes runs in WSL, while Vencord is a Windows source checkout.

```powershell
.\install.ps1 -VencordPath "$env:USERPROFILE\Vencord"
```

The installer:

- copies `vencord-userplugin/hermesStatus` to `<VencordPath>\src\userplugins\hermesStatus`;
- copies `bridge` to `<HermesHome>\plugins\discord-status`;
- creates `HERMES_DISCORD_STATUS_TOKEN` in `<HermesHome>\.env` only when it is missing or empty;
- for WSL UNC homes, creates the token temp file empty, hardens it to Linux mode `0600` through a descriptor-based `/usr/bin/python3` helper, then writes the token bytes while preserving that mode;
- preserves unrelated `.env` entries, accepts the effective last python-dotenv-style token assignment, and rewrites the token as one plain `KEY=value` line;
- replaces managed destination directories and `.env` in one managed-file transaction: backups are retained until file replacement, token update, WSL mode hardening, and requested Vencord quality gates succeed;
- runs Vencord quality gates by default: `pnpm install --frozen-lockfile`, plugin ESLint, `pnpm testTsc`, `pnpm exec tsx src/userplugins/hermesStatus/tests/statusLogic.test.ts`, and `pnpm build`;
- enables the Hermes plugin and restarts the Hermes gateway through the Hermes CLI unless skipped.

The script does not require admin rights. It takes a named single-instance mutex before validation or mutation so accidental concurrent installer runs fail before writes. It validates this source project, the Vencord checkout shape, path overlap, destination types, and destination boundaries before writing. It refuses packaged AppData/dist paths as Vencord plugin source checkouts and rejects unsafe reparse or WSL symlink destinations.

The concurrency boundary is accidental installer overlap, not a malicious concurrent process running as the same OS user. That same principal can already alter the target files directly, so same-user concurrent mutation is outside the installer's security boundary. On detected changes during cleanup or restore, the installer fails conservatively and preserves backups instead of moving changed content live.

Do not put a real token in this repository, screenshots, issue reports, or GitHub Actions logs.

### Installer parameters

```powershell
.\install.ps1 `
  -VencordPath "$env:USERPROFILE\Vencord" `
  -WslDistribution Ubuntu `
  -HermesHome '\\wsl$\Ubuntu\home\YOUR_LINUX_USER\.hermes'
```

- `-VencordPath` is required and must point at a Vencord source checkout containing `package.json` and `src\userplugins`.
- `-WslDistribution` selects a WSL distro for Hermes CLI commands and automatic Hermes home resolution. When `-HermesHome` is a WSL UNC path, the distro is inferred from that path if this parameter is omitted; if supplied, it must match the UNC distro name.
- `-HermesHome` overrides WSL home resolution. WSL UNC roots must use canonical `\\wsl.localhost\<distro>\...` or `\\wsl$\<distro>\...` paths with no `.` or `..` segments. Explicit non-WSL Windows paths are supported only with `-SkipHermesCommands`, so files cannot be installed locally while Hermes CLI operations target the default WSL distro.
- `-SkipVencordBuild` skips only the Vencord pnpm quality gates.
- `-SkipHermesCommands` skips `hermes plugins enable discord-status` and `hermes gateway restart`.
- `-ShowToken` prints the real installed token in the final summary during an executing install. With `-WhatIf`, no token value is generated or printed because that value would not be installed.
- `-WhatIf` shows the planned file changes and external commands without writing or invoking pnpm, WSL, or Hermes commands. The installer makes one top-level confirmation decision for the complete installation.

If `-HermesHome` is omitted, the installer asks WSL for `$HOME/.hermes` using a fixed shell command. Distribution names are strictly validated before being passed to `wsl.exe`.

When `-HermesHome` is a WSL UNC path, the installer validates existing Linux path components and expected object types with WSL `lstat`, rejecting symlinks and special files such as FIFOs. It resolves `wsl.exe` from the Windows system directory rather than process `PATH`, creates an empty `.env` temp file, then invokes `wsl.exe -d <distro> -- /usr/bin/python3 ...` to open the file with `O_NOFOLLOW`, verify it is a regular file under the approved Hermes home, `fchmod(0600)` it by descriptor, and verify the mode before token bytes are written. This hardening is not skipped by `-SkipHermesCommands`; that switch only skips `hermes plugins enable` and `hermes gateway restart`. If mode hardening fails, the installer rolls back the managed plugin and `.env` changes.

Existing symlinked or junction-backed managed destinations are rejected rather than followed or overwritten. If an older manual installation used `~/.hermes/plugins/discord-status` as a symlink, inspect its target first, unlink only the symlink from inside WSL, and rerun the installer; the installer will not migrate that link automatically.

Vencord quality gates may update checkout-local outputs such as `node_modules` and `dist`; those pnpm side effects are not rolled back. After managed files and `.env` are committed, Hermes CLI enable/restart failures do not roll them back. In that case, leave the installed files in place and rerun:

```powershell
wsl.exe -d <distro> -- hermes plugins enable discord-status
wsl.exe -d <distro> -- hermes gateway restart
```

To retrieve the bridge token later, read `HERMES_DISCORD_STATUS_TOKEN` from `<HermesHome>\.env` locally and paste it into the Vencord plugin settings.

### Vencord injection

The installer builds the Vencord checkout but intentionally does not patch or inject Discord. After a successful build, explicitly run Vencord's installer in development-install mode, then fully quit and restart Discord. The patched Discord `app.asar` must load the checkout's `dist/patcher.js`, not an older `%APPDATA%\Vencord\dist\patcher.js`.

A gateway-hosted Hermes plugin invocation cannot restart the gateway that is currently hosting it. Normal Windows installer use runs outside Hermes, so it can call `hermes gateway restart` unless `-SkipHermesCommands` is used.

### Manual alternative

Manual installation is still possible:

1. Copy `vencord-userplugin/hermesStatus` to `Vencord\src\userplugins\hermesStatus`.
2. Copy `bridge` to `~/.hermes/plugins/discord-status`.
3. Add a strong local `HERMES_DISCORD_STATUS_TOKEN` to `~/.hermes/.env`.
4. In the Vencord checkout, run:

   ```powershell
   pnpm install --frozen-lockfile
   pnpm exec eslint src/userplugins/hermesStatus
   pnpm testTsc
   pnpm exec tsx src/userplugins/hermesStatus/tests/statusLogic.test.ts
   pnpm build
   ```

5. Run Vencord's development installer, restart Discord, then enable and restart Hermes:

   ```bash
   hermes plugins enable discord-status
   hermes gateway restart
   ```

## Test it in Discord

1. Start Discord with the custom Vencord build installed.
2. Open **User Settings → Plugins → HermesStatus**.
3. Click **Set local bridge token**, paste the local Hermes bridge token, and save.
4. Right-click a parent channel and choose **Show Hermes status here**.
5. Send Hermes a message that creates a child thread under that parent, then open the child thread.
6. Confirm the status bar appears automatically in the child thread and remains hidden in the selected parent channel while `showInParentChannels=false`.
7. Enable **Show in selected parent channels** and confirm the bar also appears in the selected parent.
8. Separately, right-click a specific thread outside any selected parent and choose **Show Hermes status here**; confirm the bar appears in that directly selected thread.
9. Send a prompt that uses a tool and triggers a follow-up model request; confirm **Total processed** increases cumulatively while context remains the latest request size.

Using **Show Hermes status here** again disables the selected parent scope or directly selected thread. Disabling a parent scope removes its inherited enablement from child threads unless a thread is also selected directly.

## Development references

Vencord userplugins are compiled into a custom Vencord build; copying the folder into AppData alone is not sufficient.

Official Vencord references:

- https://docs.vencord.dev/installing/custom-plugins/
- https://docs.vencord.dev/plugins/

The status endpoint is:

```text
GET /v1/status/discord/<channel-or-thread-id>
```

The bridge is a standalone plugin and does not receive a live Hermes agent object. Model, context usage, total processed tokens, tool activity, session/turn timing, API errors, subagent activity, YOLO state, and optional compression count are derived only from public Hermes hook payloads and safe in-memory session state. If Hermes does not emit a compression count in hook payloads, the bridge reports `0` rather than guessing. A gateway restart discards live total accounting, so Discord shows `Total --` until a new valid session and accepted API request establish a fresh in-memory total.

To confirm the bridge is listening only on loopback after enabling the plugin:

```bash
ss -ltn '( sport = :8765 )'
```

## Continuous integration

GitHub Actions runs these validations with read-only GitHub token permissions across three jobs:

- Bridge tests on Ubuntu with Python 3.11: `pytest` and `compileall`.
- Installer tests on `windows-latest`: PowerShell parser check and `tests/install.Tests.ps1`.
- Workflow policy test on Ubuntu: parses `.github/workflows/ci.yml` and structurally enforces immutable pinned action SHAs, read-only permissions, the pinned Vencord commit, and the standalone `tsx` status test command.
- Vencord plugin validation on Ubuntu: checks out official Vencord at `94cc541e38905063988094249a40e618f83a12e4`, copies this exact userplugin, uses Node 24 and pnpm 11.9.0, then runs frozen install, plugin ESLint, `testTsc`, `pnpm exec tsx src/userplugins/hermesStatus/tests/statusLogic.test.ts`, and build.

## Repository release checklist

Before publishing:

- [ ] Add screenshots or a short demo GIF with no private Discord content.
- [x] Replace this local-install section with a tested `install.ps1`.
- [x] Add a GitHub Actions workflow for bridge tests and Vencord type checking.
- [x] Verify no secrets with `git grep -n -i 'token\|api.key\|password'` and inspect every hit.
- [x] Never commit `.env`, Vencord settings, `node_modules`, `dist`, or local Discord paths.
- [x] Set a local Git identity before the first commit.

## Layout

```text
hermes-discord-status/
├── .github/
│   └── workflows/
│       └── ci.yml
├── bridge/                         # Hermes external plugin
│   ├── plugin.yaml
│   ├── server.py
│   ├── routing.py
│   └── tests/
├── tests/
│   ├── install.Tests.ps1
│   └── workflow_policy_test.py
├── vencord-userplugin/
│   └── hermesStatus/               # Copy into Vencord/src/userplugins/
├── install.ps1
├── install.helpers.ps1
├── README.md
├── LICENSE
└── .gitignore
```
