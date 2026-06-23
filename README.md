<div align="center">

# Palmier Slate

A local-first fork of [Palmier Pro](https://github.com/palmier-io/palmier-pro).

This fork removes telemetry, accounts, subscriptions, hosted generation, and most background network connections while keeping the editor, local features, and MCP workflows.

Why? Because Palmier Pro is a great editor. It feels good to use, it's modern, open-source, native, and lightweight. It is lighter than FCP/Premiere/DaVinci, while still being more usable than all other open-source editors I have tried.

<a href="https://github.com/nikolan123/palmier-slate/releases/latest/">
  <img src="./assets/macos-badge.png" alt="Download Palmier Slate for macOS" width="180" />
</a>

<sub><i>Requires macOS 26 (Tahoe) on Apple Silicon</i></sub>

</div>

---

### Swift-native video editor

Palmier Slate is built from the ground up using native frameworks.

### Integrates with your agents

Connect Claude, Codex, Cursor, or other MCP clients to the open project. The MCP server is local and only runs when enabled in the app.

## MCP server

When the app is open, it exposes an MCP server at `http://127.0.0.1:19789/mcp` via HTTP. To connect:

**Codex**

```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

**Claude Code**

```bash
claude mcp add --transport http palmier-pro http://127.0.0.1:19789/mcp
```

**Cursor**

The easiest way is to open `Help` -> `MCP Instructions` -> `Install in Cursor`, or install manually by adding this to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "palmier-pro": {
      "type": "http",
      "url": "http://127.0.0.1:19789/mcp"
    }
  }
}
```

**Claude Desktop**

The app bundles an [mcpb](https://github.com/modelcontextprotocol/mcpb) for one-click Claude Desktop installation. Go to `Help` -> `MCP Instructions` -> `Install in Claude Desktop`.

## FAQ

**Is Palmier Slate fully open source?**

Yes.

**Is it free?**

Yes.

**What platforms does it support?**

macOS 26 (Tahoe) on Apple Silicon only.

## License

Copyright (C) 2026 Palmier, Inc.

Palmier Slate is a fork of Palmier Pro. Original code remains copyright Palmier, Inc.; fork changes are distributed under [GPLv3](LICENSE).
