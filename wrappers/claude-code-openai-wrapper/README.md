# Claude Code OpenAI Wrapper

> **Vendored from:** [RichardAtCT/claude-code-openai-wrapper](https://github.com/RichardAtCT/claude-code-openai-wrapper)  
> **Original Author:** Richard Collins ([RichardAtCT](https://github.com/RichardAtCT))  
> **License:** See original repository

FastAPI application that wraps the Claude Code CLI agent and exposes it as an OpenAI-compatible HTTP endpoint.

---

## What This Does

Allows you to use the **Claude Code agent** (Anthropic's official CLI with tools, file operations, and multi-turn sessions) through a standard OpenAI-compatible API. Perfect for:
- Integrating Claude Code with LiteLLM
- Using Claude Code in OpenClaw or other OpenAI-compatible clients
- Running Claude Code behind a reverse proxy

## home-lab Integration

This wrapper is deployed as part of the home-lab AI agent stack:

```
OpenClaw → LiteLLM → claude-code-wrapper:8000 → Claude Code CLI (OAuth) → api.anthropic.com
```

**Key features in home-lab deployment:**
- Runs inside an OpenShell sandbox (`openshell-claude-revproxy`)
- OAuth-only authentication (Claude Pro/Max subscription)
- No Bedrock credentials needed in sandbox
- Connected to Docker `ai-net` bridge as `claude-code-wrapper`
- Exposed through LiteLLM as `claude-code-wrapper-local`

## Installation (home-lab)

**Automated setup:**
```bash
bootstrap/setup-claude-revproxy.sh
```

This script:
1. Creates/verifies OpenShell sandbox
2. Syncs OAuth credentials from host
3. Copies wrapper code to sandbox
4. Installs dependencies
5. Starts uvicorn on `:8000`

**Manual installation** (inside sandbox):
```bash
pip install --break-system-packages -r requirements.txt
```

## Configuration

**Environment variables:**

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_CODE_AUTH_METHOD` | `cli` | Auth method (`cli` = OAuth, `bedrock` = AWS) |
| `API_KEY` | `claude-code-internal-revproxy-key-2026` | Bearer token for LiteLLM → wrapper auth |
| `RATE_LIMIT_ENABLED` | `false` | Enable rate limiting (disabled for internal use) |
| `CLAUDE_CWD` | `/tmp` | Working directory for Claude Code file operations |

**OAuth credentials:**
- Host: `~/.claude/.credentials.json`
- Sandbox: `/root/.claude/.credentials.json` (synced via `bootstrap/sync-claude-credentials.sh`)

## Related Documentation

- [docs/current/claude-code-wrapper.md](../../docs/current/claude-code-wrapper.md) — Comprehensive operational guide
- [docs/diagrams/claude-code-wrapper-data-flow.md](../../docs/diagrams/claude-code-wrapper-data-flow.md) — Data flow diagram
- [bootstrap/setup-claude-revproxy.sh](../../bootstrap/setup-claude-revproxy.sh) — Deployment script

## License

Original work by [RichardAtCT](https://github.com/RichardAtCT). See [upstream repository](https://github.com/RichardAtCT/claude-code-openai-wrapper) for license details.

home-lab modifications are part of the home-lab repository.
