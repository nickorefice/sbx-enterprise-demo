# Add-on 04 — Dev-Velocity Kits  [Dev]

**Goal**: Show how developers compose reusable kit mixins — stack them like LEGO, load them from a Git URL for reproducibility, and let agentContext deliver instructions automatically without custom wrapper scripts.

**Audience**: Developer champions, platform teams building internal developer tools, anyone evaluating kit composability for a multi-team rollout.

---

## Prerequisites

- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally (`github.com/nickorefice/sbx-enterprise-demo`)
- Network access to `pypi.org` and `astral.sh` (for the ruff install step inside the sandbox) — or use the golden template (add-on 03) which pre-installs ruff
- `services/vote/app.py` present and containing Python code for ruff to check

---

## Background

A kit mixin does three things:

1. **Installs tooling** inside the sandbox at creation time (`commands.install`, run as the agent user with `user: "1000"`)
2. **Drops configuration files** into the workspace — any file under the kit's `files/workspace/` directory is copied as-is into the sandbox, so the agent and all tools share identical settings
3. **Instructs the agent** via `agentContext` — a block of text injected into the agent's system prompt at startup, so the agent knows what tools are available and how to use them

Kits are composable: you can pass `--kit` multiple times to a single `sbx run` command. Each kit's network allowlist is merged, its install commands run sequentially, and its `agentContext` blocks are concatenated. Kits do not need to know about each other.

---

## Step 1: Show the Ruff-Lint Mixin

Inspect the kit spec and the config file it deploys:

```bash
cat kits/ruff-lint/spec.yaml
```

```bash
cat kits/ruff-lint/files/workspace/ruff.toml
```

Walk through the `spec.yaml` sections:

| Section | What it does |
|---------|-------------|
| `commands.install` | Runs `uv tool install ruff@latest` once at sandbox creation, as the agent user (`user: "1000"`) |
| `files/workspace/ruff.toml` | Static config — copied as-is into the sandbox workspace at creation (no `initFiles` entry needed for static files) |
| `network.allowedDomains` | Adds `pypi.org`, `files.pythonhosted.org`, `astral.sh` to the allowlist for the install step |
| `agentContext` | Injected into the agent's system prompt — tells it to run `ruff check` and `ruff format` before every commit |

**SAY**: "A mixin kit installs ruff, drops a shared config into the workspace, and tells the agent to run it before committing. The agent gets the instruction via agentContext — no prompting required."

Point out the `ruff.toml` configuration: `line-length = 100`, `target-version = "py311"`, and a curated set of lint rules. Every sandbox that uses this kit gets identical linting rules regardless of who created it or when.

---

## Step 2: Stack Two Kits

Combine the network cage from `cage-policy` with the linting from `ruff-lint` in a single command:

```bash
# ▶ host-validate — network cage + linting in one command
sbx run claude \
  --kit ./kits/cage-policy \
  --kit ./kits/ruff-lint \
  -- --dangerously-skip-permissions \
  "Fix any ruff errors in services/vote/app.py, then commit 'lint: fix ruff errors in vote service'"
```

**EXPECT**: The agent runs `ruff check services/vote/app.py`, fixes any violations, runs `ruff format`, and commits the result. If the file is already clean, it will say so and make no commit.

**SAY**: "Two kits, stacked. The network cage from cage-policy, the linting from ruff-lint. Neither knows about the other. The allowlists merge, the install commands run in order, the agentContext blocks concatenate. Compose like LEGO."

Highlight what the merge produces:
- **Network**: vote service can reach `api.anthropic.com`, `github.com`, `pypi.org`, `astral.sh` — the union of both kits' allowlists, minus the cage-policy denylists
- **Agent instructions**: the agent sees both cage-policy's context (if any) and ruff-lint's linting instructions in its system prompt

---

## Step 3: Load a Kit via Git URL

Demonstrate that any developer on any machine — with no local clone of the repo — can load the same kit:

```bash
# ▶ host-validate — same kit, loaded from git, works on any machine
sbx run claude \
  --kit "git+https://github.com/nickorefice/sbx-enterprise-demo.git#dir=kits/ruff-lint" \
  -- --dangerously-skip-permissions \
  "Run ruff check on services/vote/app.py and show me the output"
```

**EXPECT**: The agent reports ruff check results. The kit was fetched from GitHub at `sbx run` time — no local clone required.

**SAY**: "Same kit, loaded from a git URL. Any developer on any machine gets an identical setup. No 'works on my laptop' — the kit IS the setup."

The git URL format supports:
- A branch or tag: `git+https://...#ref=v1.2&dir=kits/ruff-lint` (pins to a released version)
- The default branch: `git+https://...#dir=kits/ruff-lint` (always latest)

For reproducibility in CI or regulated environments, pin to a commit SHA or tag rather than the default branch.

---

## Step 4: Show the agentContext Instruction

Inspect what the agent actually reads at startup:

```bash
# What the agent reads at startup from the ruff-lint kit
grep -A5 "agentContext" kits/ruff-lint/spec.yaml
```

**EXPECT**:

```yaml
agentContext: |
  ## Linting
  ruff is installed and configured. Before committing any Python changes:
    ruff check .         # lint
    ruff format .        # format
  Config lives at /workspace/ruff.toml. Fix all errors before committing.
```

**SAY**: "agentContext is the agent's operating manual for this kit. It's injected into the system prompt automatically — no wrapper scripts, no custom entrypoints. Write it once in the kit, and every agent that uses the kit follows the same workflow."

Compare this to the alternative: encoding instructions in a per-task prompt, a custom CLAUDE.md, or a wrapper shell script. Any of those requires coordination between the person writing the task and the person who set up the environment. With `agentContext`, the kit ships its own instructions — they are inseparable from the tooling.

---

## Reset

Clean up the sandbox between demo runs:

```bash
# ▶ host-validate (prompts for confirmation; add --force to skip)
sbx rm claude
```

If you ran multiple sandboxes with the same name in sequence, sbx will use the most recent one. Verify with `sbx ls` before removing if unsure.

---

## Additional Notes

**Writing your own kit**: A minimal kit is a directory with a single `spec.yaml`. The `files/` subdirectory is optional — only needed if the kit copies config files into the workspace. Start from the `kits/ruff-lint/` directory as a template.

**Kit versioning strategy**: Use git tags to version kits. Reference `git+https://...#ref=v2.0&dir=kits/ruff-lint` in your team's `sbx run` scripts for stability. Your platform team can publish new kit versions as tags without breaking existing usages.

**agentContext length**: Keep `agentContext` focused and concise. It is injected into the system prompt for every message exchange, so verbose context increases token usage. Cover what tools are available, how to invoke them, and any non-obvious conventions. Leave detailed documentation in the kit's README.

**Kit registry**: For large organizations, consider hosting kits in a dedicated internal repository with CODEOWNERS on each kit directory. This gives you team ownership, review gates, and a single source of truth for all approved kit configurations.

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Show spec.yaml and ruff.toml | Self-validated (file read) | No sbx CLI required |
| Step 2 — Stack two kits | **host-validate** | Requires sbx CLI; network must allow pypi.org and astral.sh |
| Step 3 — Load kit via Git URL | **host-validate** | Requires sbx CLI and network access to github.com |
| Step 4 — Show agentContext | Self-validated (grep local) | No sbx CLI required |
| Reset — `sbx rm claude` | **host-validate** | Requires sbx CLI |
