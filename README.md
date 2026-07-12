# Hermes Discord Status

A private, local-only live status bar for Hermes Agent in Discord.

It combines two components:

- `bridge/` — a standalone Hermes external plugin. It exposes a minimal authenticated status API on `127.0.0.1`.
- `vencord-userplugin/hermesStatus/` — a Vencord userplugin. Selecting a parent channel is an explicit scope selector for Hermes-created child threads under it; each inherited child thread still polls the bridge with its own exact thread ID. Selecting a specific thread enables that thread directly. Selected parent channels hide the bar by default unless `showInParentChannels` is enabled.

## What it shows

- active model
- current context used / maximum, 10-segment gauge, and percentage
- compression count and active subagent count
- current-turn and session timers
- bridge update freshness and YOLO indicator when active
- active tool and tool-call count
- connected, stale, disconnected, or error state

It does **not** add a footer to Discord messages. It does **not** send status data to any remote service.

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

## Current local installation

This working copy is a clean source project for editing and eventual publication. The active local installation is currently sourced from:

- Hermes bridge source: `/home/mohammed/projects/hermes-discord-status`
- Vencord userplugin source: `C:\Users\mohammed\Vencord\src\userplugins\hermesStatus`

Do not put a real token in this repository, screenshots, issue reports, or GitHub Actions logs.

## Test it in Discord

1. Start Discord with the custom Vencord build installed.
2. Open **User Settings → Plugins → HermesStatus**.
3. Click **Set local bridge token**, paste the local Hermes bridge token, and save.
4. Right-click a parent channel and choose **Show Hermes status here**.
5. Send Hermes a message that creates a child thread under that parent, then open the child thread.
6. Confirm the status bar appears automatically in the child thread and remains hidden in the selected parent channel while `showInParentChannels=false`.
7. Enable **Show in selected parent channels** and confirm the bar also appears in the selected parent.
8. Separately, right-click a specific thread outside any selected parent and choose **Show Hermes status here**; confirm the bar appears in that directly selected thread.

Using **Show Hermes status here** again disables the selected parent scope or directly selected thread. Disabling a parent scope removes its inherited enablement from child threads unless a thread is also selected directly.

## Development setup on Windows

Vencord userplugins are compiled into a custom Vencord build; copying the folder into AppData alone is not sufficient.

1. Clone the official Vencord source repository.
2. Copy `vencord-userplugin/hermesStatus` into `Vencord/src/userplugins/hermesStatus`.
3. From PowerShell in the Vencord checkout:

   ```powershell
   pnpm install --frozen-lockfile
   pnpm exec eslint src/userplugins/hermesStatus
   pnpm testTsc
   pnpm build
   ```

4. Install the development build using Vencord's installer in development-install mode. The patched Discord `app.asar` must load the **checkout's** `dist/patcher.js`, not an older `%APPDATA%\Vencord\dist\patcher.js`.
5. Fully quit and restart Discord.

Official Vencord references:

- https://docs.vencord.dev/installing/custom-plugins/
- https://docs.vencord.dev/plugins/

## Hermes bridge installation

The bridge is an external Hermes plugin. On the machine running Hermes:

1. Copy or symlink the contents of `bridge/` to `~/.hermes/plugins/discord-status/`.
2. Generate a random local bearer token and store it only in `~/.hermes/.env` as `HERMES_DISCORD_STATUS_TOKEN`.
3. Enable the plugin:

   ```bash
   hermes plugins enable discord-status
   hermes gateway restart
   ```

4. Confirm the bridge is listening only on loopback:

   ```bash
   ss -ltn '( sport = :8765 )'
   ```

The status endpoint is:

```text
GET /v1/status/discord/<channel-or-thread-id>
```

The bridge is a standalone plugin and does not receive a live Hermes agent object. Model, context usage, tool activity, session/turn timing, API errors, subagent activity, YOLO state, and optional compression count are derived only from public Hermes hook payloads and safe session state. If Hermes does not emit a compression count in hook payloads, the bridge reports `0` rather than guessing.

## Repository release checklist

Before publishing:

- [ ] Add screenshots or a short demo GIF with no private Discord content.
- [ ] Replace this local-install section with a tested `install.ps1`.
- [ ] Add a GitHub Actions workflow for bridge tests and Vencord type checking.
- [ ] Verify no secrets with `git grep -n -i 'token\|api.key\|password'` and inspect every hit.
- [ ] Never commit `.env`, Vencord settings, `node_modules`, `dist`, or local Discord paths.
- [ ] Set a local Git identity before the first commit.

## Layout

```text
hermes-discord-status/
├── bridge/                         # Hermes external plugin
│   ├── plugin.yaml
│   ├── server.py
│   ├── routing.py
│   └── tests/
├── vencord-userplugin/
│   └── hermesStatus/               # Copy into Vencord/src/userplugins/
├── README.md
├── LICENSE
└── .gitignore
```
