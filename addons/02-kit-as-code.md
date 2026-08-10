# Add-on 02 — Kit-as-Code: The Agent Provisioning Contract  [Security]

**Goal**: Show that how an agent is provisioned — the tools it gets, the environment it runs in, the files in its workspace, what runs at startup, and the instructions it follows — is declared as **reviewable code** in a single `spec.yaml`, gated by pull-request review. Every capability is in the file: no hidden setup script, no "works on my laptop" drift.

**Audience**: CISOs, security architects, compliance engineers, platform teams — anyone who needs to answer "what exactly is in an agent's environment, and who approved it?"

---

## Prerequisites

- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally (`github.com/nickorefice/sbx-enterprise-demo`)
- `python3` available locally (for the YAML-lint fallback in Step 2)
- For the tool installs (Step 3): the sandbox able to reach `pypi.org`/`files.pythonhosted.org`/`astral.sh` (detect-secrets) and `raw.githubusercontent.com`/`github.com` (Docker Scout CLI) — granted via **org governance** (network is org-owned, not declared in the kit), or pre-baked into the golden template (add-on 03). No special template is needed to run `docker scout`: `sbx run claude` defaults to the Docker-enabled variant, so every sandbox ships with its own isolated in-sandbox Docker engine (`docker-next`).

---

## Background

In sbx, a **kit** (mixin) is a directory containing a `spec.yaml` that declaratively describes an agent's environment. This add-on demonstrates the **five capability types** a kit declares as code, all with one kit, `secure-baseline`:

| # | Capability | spec.yaml section | What it does |
|---|-----------|-------------------|--------------|
| 1 | **Tools to install** | `commands.install` | Installs **Docker Scout** (image CVE/SBOM scanning) and `detect-secrets` once at creation (as the agent user) |
| 2 | **Environment variables** | `environment.variables` | Sets non-secret org config: curated Docker Hub base-image namespace, build platform, telemetry opt-out, compliance profile |
| 3 | **Files to drop in** | `files/` (static) + `commands.initFiles` (runtime-substituted) | Ships a coding-standards doc and a per-sandbox provenance file |
| 4 | **Startup commands** | `commands.startup` | Writes a provisioning status stamp on every start (idempotent) |
| 5 | **Memory instructions** | `agentContext` | Injects org conventions into the agent's memory |

> **Why no network allow/deny rules in this kit?**
> In a governed enterprise, **org-level governance owns network and filesystem access and overrides any kit network rules** (see the box at the end of this doc). A network allowlist declared in a kit is therefore noise in the environments these buyers actually run — documentation at best, silently overridden at worst. So this kit covers everything org governance does *not* manage and leaves the network cage to org governance. (For ungoverned/individual use, a kit allowlist *does* still apply — but that's not the enterprise story.) For the network cage itself, see RUNBOOK Beat 3 (default-deny network) and your org governance policy.

> **Composable.** This add-on uses the comprehensive `secure-baseline` kit on its own. Kits also stack — add-on 04 layers `secure-baseline` (the org baseline) with `ruff-lint` (a team add-on) in a single `sbx run`.

---

## Step 1: Show the Whole Provisioning Contract as Code

```bash
# The kit's declared environment — tools, env, files, startup, memory —
# lives in one file, in git, reviewable like any other code.
cat kits/secure-baseline/spec.yaml
```

Walk through it top to bottom against the capability table above. The point to land:

**SAY**: "This one file *is* the agent's environment. Every tool it has, every variable it runs with, every file in its workspace, what runs when it boots, and the instructions it follows — all declared here, all in git, all going through pull-request review, scanned by your SAST tools, and gated by CODEOWNERS on the `kits/` directory. There is no hidden setup script, no 'works on my laptop' drift. The kit is the environment, and the environment is code."

Then show the static file the kit ships (capability #3):

```bash
cat kits/secure-baseline/files/workspace/CODING-STANDARDS.md
```

**SAY**: "Anything under `files/workspace/` is copied as-is into every sandbox. One source of truth for coding and security standards, versioned with the kit."

---

## Step 2: Validate the Kit Structure

**Option A — sbx CLI validation (preferred):**

```bash
sbx kit validate ./kits/secure-baseline
```

**EXPECT**: `kit is valid` or equivalent success output. Any schema violations print as structured errors.

---

## Step 3: Prove the Kit's Capabilities Landed

The kit provisioned the entire non-secret environment in one shot. One agent run inspects it — installed tooling, environment variables, the static file, the runtime-substituted file, and the startup stamp:

```bash
# ▶ host-validate
sbx run claude --kit ./kits/secure-baseline \
  -- --dangerously-skip-permissions -p \
  "Report each item and nothing else: \
   (1) the values of CORP_COMPLIANCE_PROFILE, BASE_IMAGE_NAMESPACE, and DOCKER_DEFAULT_PLATFORM; \
   (2) run 'docker scout version' and 'detect-secrets --version' and report both; \
   (3) the first heading line of ./CODING-STANDARDS.md; \
   (4) the contents of ~/.config/sbx-baseline/provenance.json; \
   (5) the contents of ~/.config/sbx-baseline/status"
```

**EXPECT**, mapping back to the capability table:

| Reported item | Proves capability | What you should see |
|---|---|---|
| (1) env vars | **#2 Environment variables** | `CORP_COMPLIANCE_PROFILE=soc2-baseline`, `BASE_IMAGE_NAMESPACE=docker.io/nicksdemoorg`, `DOCKER_DEFAULT_PLATFORM=linux/amd64` |
| (2) `docker scout version` + `detect-secrets --version` | **#1 Tools to install** | both print versions — both scanners were installed at creation |
| (3) `CODING-STANDARDS.md` heading | **#3 Files (static)** | `# Org Coding Standards (injected by the secure-baseline kit)` |
| (4) `provenance.json` | **#3 Files (initFiles substitution)** | valid JSON with `"workspace"` set to the **real workspace path** — `${WORKDIR}` was substituted at write time |
| (5) `status` | **#4 Startup command** | `secure-baseline active; compliance=soc2-baseline` — the startup command ran *and* read the env var from capability #2 |

**SAY**: "One kit, applied once, provisioned the whole environment deterministically. The tool is installed, the curated Docker Hub base-image namespace is set, the standards doc is in the workspace, the provenance file had the workspace path substituted in at boot, and the startup stamp confirms the boot hook ran and saw the compliance profile. Nobody ran a setup script. Nobody could forget a step. The environment is a build artifact of the kit."

> **Why two file mechanisms?** `files/` ships **static** content copied as-is (the standards doc). `commands.initFiles` writes content with **runtime substitution** like `${WORKDIR}` (the provenance file), for anything that depends on values not known until the sandbox exists.

---

## Step 4: Show the Memory Instruction (capability #5)

Inspect what the kit injects into the agent's memory at startup:

```bash
# What the agent reads at startup from the kit (self-validated; local grep)
grep -A12 "agentContext" kits/secure-baseline/spec.yaml
```

**EXPECT**: the `## Secure service baseline` block — image scanning with `docker scout cves`, mandatory secret scanning (`detect-secrets` before every commit), curated Docker Hub base images, and standards in `CODING-STANDARDS.md`.

**SAY**: "`agentContext` is the kit's operating manual for the agent, injected into its memory automatically — no wrapper scripts, no custom entrypoint. The instructions ship *with* the tooling they describe, so the agent that gets `detect-secrets` and Docker Scout also gets told when to run each. Write it once in the kit; every agent that uses the kit follows the same conventions."

---

## Step 5: Show the Audit Trail

After the runs above, inspect the connection log:

```bash
sbx policy log
```

**EXPECT**: A table showing each domain the sandbox attempted to contact, the rule matched, and the last-seen timestamp — including the install hosts (`pypi.org`/`astral.sh` for detect-secrets, `raw.githubusercontent.com`/`github.com` for Docker Scout) and `api.anthropic.com` (Claude API traffic).

**SAY**: "This is your runtime audit log. Every outbound connection attempt, allowed or denied, timestamped. Pair this with your SIEM and you have full observability over agent network behavior — every host the kit's tooling reached, on the record."

---

> **IMPORTANT — Org Governance owns the network/filesystem cage, not the kit**
>
> Under active org-level governance, **org network and filesystem rules replace kit-level rules entirely** — "local rules are no longer evaluated." If your org policy denies a domain, no kit can allow it; if your org policy allows a domain, a kit cannot block it.
>
> That is exactly why this kit declares **no** `allowedDomains`/`deniedDomains`: in a governed org they would be noise. The division of responsibility is:
>
> | Concern | Where it lives | Who owns it |
> |---|---|---|
> | Network + filesystem cage | Org governance (Docker Admin Console / Governance API) | Security / IT |
> | Tools, env, files, startup, memory | The kit (`kits/secure-baseline/spec.yaml`) | Team / platform |
>
> Everything org governance does *not* manage lives in the reviewable kit. The network cage *is* governed centrally, so it belongs at the org level. See `POLICIES.md` for the full model.

---

**SAY for CISO audience**: "Git history IS your audit log for the agent's *environment* — who added which tool, changed which standard, updated which startup step, when, and why — all in the commit, reviewed like any other code, with CODEOWNERS gating the `kits/` directory. The enforcement mechanism is the proxy and the microVM; the network cage is governed by org policy; the agent's environment is governed by your existing git workflow — each governed where it's actually enforced."

---

## Reset

```bash
sbx rm claude
```

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Show spec.yaml + static file | Self-validated (file read) | No sbx CLI required |
| Step 2A — `sbx kit validate` | **host-validated ✓** | Returns `VALID` with no deprecation warnings |
| Step 2B — YAML lint | Self-validated (python3) | `kits/secure-baseline/spec.yaml` confirmed well-formed YAML |
| Step 3 — Kit capabilities landed | **host-validated ✓** | Confirmed live (env vars, startup stamp). Installs need pypi.org/astral.sh + raw.githubusercontent.com/github.com (or the golden template); `docker scout` runs on the default Docker-enabled sandbox (`docker-next`) — no special template needed |
| Step 4 — Show agentContext | Self-validated (grep local) | No sbx CLI required |
| Step 5 — Audit trail (`sbx policy log`) | **host-validate** | Run while sandbox still exists |
