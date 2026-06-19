# Design Patterns

> **Reusable architectural patterns for home-lab components**

This directory contains design pattern documentation that describes **how to build** 
components in the home-lab stack, not what's currently built (that's in `docs/current/`).

---

## Available Patterns

### [CLI-to-API Wrapper Pattern](cli-to-api-wrapper.md)

**When to use:** Wrapping OAuth-authenticated agent CLIs (Claude Code, Grok Build, Codex, 
Gemini, Copilot) as OpenAI-compatible HTTP endpoints.

**What it covers:**
- FastAPI wrapper structure
- OpenShell sandbox integration
- LiteLLM routing configuration
- OAuth credential management
- Testing strategy
- Complete implementation checklist

**Examples:** `claude-code-wrapper-local`, `grok-wrapper-local`

**Use this for:** Phase 5 (Codex), Phase 6 (Gemini), future agent CLI integrations

---

## How to Use These Patterns

1. **Read the pattern** — Understand the architecture and when to apply it
2. **Follow the checklist** — Step-by-step implementation guide
3. **Use the templates** — Copy/paste code templates and adjust for your use case
4. **Test incrementally** — Local → Sandbox → LiteLLM → OpenClaw
5. **Document thoroughly** — Create wrapper-specific docs in `docs/current/`

---

## Pattern Categories

### Integration Patterns
- [CLI-to-API Wrapper](cli-to-api-wrapper.md) — Wrapping OAuth-based agent CLIs

### Planned Patterns
- **Service Deployment** — Docker Compose → k8s migration path
- **Sandbox Policy Design** — OpenShell network/filesystem/process policies
- **Credential Management** — OAuth sync, rotation, systemd timers
- **LiteLLM Routing** — Model registration, aliasing, fallback chains

---

## Contributing New Patterns

When you build something reusable, document the pattern:

1. **Identify the abstraction** — What problem does this solve generically?
2. **Create pattern doc** — `docs/patterns/pattern-name.md`
3. **Include templates** — Code snippets that can be copied and adjusted
4. **Provide examples** — Link to concrete implementations in the repo
5. **Update this README** — Add to the list above

**Good patterns:**
- Solve a category of problems, not one specific instance
- Include complete implementation checklists
- Provide working code templates
- Reference actual examples in the codebase

**Bad patterns:**
- Too specific (just document the implementation instead)
- Too abstract (no concrete templates or examples)
- Missing key steps (can't be reproduced from the doc alone)

---

## Related Documentation

- [docs/current/](../current/) — Current state of deployed components
- [docs/future/](../future/) — Long-term vision and roadmap
- [docs/diagrams/](../diagrams/) — Architecture diagrams
- [wrappers/](../../wrappers/) — Wrapper implementations
- [openshell/](../../openshell/) — Sandbox policies and configs
- [bootstrap/](../../bootstrap/) — Setup and deployment scripts
