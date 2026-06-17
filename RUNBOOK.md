# sbx Enterprise Demo — Runbook

> **Audience**: AE / SE presenting to a technical or governance-focused enterprise buyer.
> **Total runtime**: ~23 min (Beats 0–6) plus Q&A buffer.
> **Tone**: Conversational but precise. Every claim is proved live — resist the urge to skip ahead.

---

## Prerequisites

Confirm all of the following are in place **before** walking into the room.

| Requirement | Check |
|---|---|
| `sbx` CLI installed and authenticated | `sbx version` |
| `gh` CLI installed | `gh --version` |
| `docker` daemon running on the host | `docker info` |
| Demo workspace cloned | `ls ~/Documents/GitHub/sbx-enterprise-demo` |
| `EXAMPLE_API_KEY` set in host environment or sandbox secret store | `echo $EXAMPLE_API_KEY` (should print the real value on host) |
| Network policy allows this workspace's domains | `sbx policy ls` |

---

## Demo Sandbox

All commands that target a named sandbox use **`demo-agent`**.
Workspace root: `~/Documents/GitHub/sbx-enterprise-demo`

The sandbox is created in Beat 1 and torn down in the Reset section at the end of this document.

---

## Beat 0 — Prep & Context (2 min)

### Setup

Open your terminal in the workspace root. Keep a second pane ready for host-side commands — you will deliberately switch between "inside the VM" and "on the host" to make the boundary tangible.

```bash
# What we're working with
ls
```

**EXPECT**

```
addons/   kits/   services/   templates/
```

```bash
# Skim the repo anatomy in one shot
cat README.md
```

Point to the `kits/` directory — that is where policy lives. Point to `services/` — that is the demo app the agent will touch. Point to `templates/golden/` — that is the enterprise-hardened base image.

---

**SAY**: "Every AI coding agent I'm about to spin up lives in its own microVM — separate kernel, separate Docker daemon, network off by default, and credentials that never enter the box. We're going to prove each of those claims, live, one layer at a time."

---

## Beat 1 — Layer 1: Separate Linux Kernel (3 min)

**SAY**: "Let's start at the bottom: the kernel. If this were a container, the agent and I would share a kernel. It's not."

```bash
# Spin up the demo sandbox (this takes ~10 s on a warm cache)
# `sbx create AGENT PATH` — claude is the agent, "." is the workspace (the repo root)
sbx create --name demo-agent claude .
```

**EXPECT**: A sandbox ID printed and a status line confirming the microVM is running.

```bash
# Ask the sandbox what kernel it's running (-s name, -r release, -m arch)
sbx exec demo-agent -- uname -srm
```

**EXPECT**: `Linux 7.0.8 aarch64` (or similar) — the kernel name is **Linux**.

```bash
# Compare against the host kernel
uname -srm
```

**EXPECT** (on a macOS host): `Darwin 23.6.0 arm64` (or similar) — the kernel name is **Darwin**.

The contrast is the point: the host runs the **Darwin** (XNU) kernel, the sandbox runs a separate **Linux** kernel. Even on a Linux host — where both say `Linux` — the release strings differ and the namespace isolation still holds: the sandbox cannot see the host's kernel modules or `/proc` tree.

---

**SAY**: "Different kernel. The agent is in a microVM — not a container, not a namespace trick. A real VM boundary. There is no shared kernel to exploit."

**▸ Gov aside**: "This means a compromised agent cannot use kernel exploits to escape to the host. The attack surface is a VM boundary, not a Linux namespace. Container escapes that rely on kernel vulnerabilities — like dirty-pipe or runc CVEs — are structurally irrelevant here."

---

## Beat 2 — Layer 2: Own Docker Engine (3 min)

**SAY**: "The agent has its own Docker engine. When it spins up a container — say, to run a test database — that container lives inside the VM, not on your host."

```bash
# The sandbox has its own dockerd — not the host's
sbx exec demo-agent -- docker ps
```

**EXPECT**: An empty container list — the sandbox's Docker daemon is fresh with no containers.

```bash
# The host's Docker daemon shows the sandbox itself, not the agent's containers
docker ps
```

**EXPECT**: The host `docker ps` lists the sandbox VM (and any other host-level containers), but the agent's `docker ps` output is completely separate.

---

**SAY**: "Two separate container inventories. An agent that spins up containers is spinning them up inside the VM — not on your host, not in your host's network namespace, not in your host's image cache."

**▸ Gov aside**: "Agent-launched containers don't appear in your host's container inventory. A supply-chain attack that tricks an agent into pulling a malicious image cannot reach host-level Docker. The blast radius is the VM."

> **If they bring up Enhanced Container Isolation (ECI):** Agree — it's the right instinct. ECI swaps `runc` for the Sysbox runtime, puts every container in a Linux user namespace, and **blocks `docker.sock` bind-mounts by default** (with admin-curated exceptions). Then draw the distinctions:
> - **Adoption:** ECI is Docker Business + admin-enabled via Settings Management — opt-in, not default. Most DD customers aren't running it, so their default posture is still one shared daemon where socket access = control of the host VM. sbx is per-agent isolated **by default**, no Business tier or fleet rollout required.
> - **Shared kernel vs. separate kernel:** ECI isolates containers *within the single Docker Desktop VM* — they still share that one kernel (Beat 1). sbx gives each agent its **own microVM and kernel**; VM-kernel exploits in scope for ECI are structurally irrelevant here.
> - **Blocks the socket vs. full Docker, safely:** ECI's answer is to *block* the socket, which can break agents that genuinely need Docker. sbx lets the agent use Docker **unrestricted** against its **own throwaway daemon** — full capability *and* contained.
> - **Scope:** ECI hardens container → host-VM isolation. sbx is the full cage per agent — own kernel + own dockerd + default-deny egress + scoped filesystem (you choose what's mounted, read-write or read-only) + proxy-injected credentials — and `sbx rm` wipes all of it.
>
> **Land it:** "ECI hardens your developers' interactive containers. sbx is the purpose-built cage for autonomous agents. They're complementary."

---

## Beat 3 — Layer 3: Default-Deny Network (5 min)

**SAY**: "Network. By default, the agent cannot reach anything on the internet. Watch what happens when I ask it to try."

```bash
# Ask the agent to attempt an outbound request — it will be blocked
sbx run demo-agent -- --dangerously-skip-permissions \
  "Try to curl example.com and show me the exact output, including any errors"
```

**EXPECT**: The agent reports an HTTP 403 from the proxy with a message along the lines of:

```
Blocked by network policy: domain example.com
  detail: no matching allow rule — blocked by default deny policy
```

Now show where the allowlist comes from:

```bash
# The active network rules and their origin (org, system, or default-deny)
sbx policy ls
```

**EXPECT**: The approved domains — `api.anthropic.com`, `github.com`, Docker Hub, and a handful of others — each tagged with its origin. Under org governance these are set centrally (Docker Admin Console / Governance API), apply to every sandbox uniformly, and can't be overridden locally; everything not on the list falls through to default-deny.

```bash
# The proxy log shows every blocked attempt, with timestamps
sbx policy log
```

**EXPECT**: A table of recent connection attempts, each showing the destination host, the rule that matched (or the default-deny fallback), and a last-seen timestamp.

---

**SAY**: "Default deny. The agent tried to reach the internet — blocked. The allowlist is set by org governance — centrally, by your security team — and everything else is denied by default. The policy log is your audit trail."

**▸ Gov aside**: "No data exfiltration via `curl`. No C2 callbacks. Egress is an explicit opt-in, not the default. The allowlist lives in org governance — the Docker Admin Console or Governance API — so it applies to every sandbox uniformly and cannot be overridden by a developer or a kit. Changes go through your governed workflow for your security team to review before they take effect. (Add-on 02 shows the flip side: what *does* belong in a reviewable kit — credential injection.)"

---

## Beat 4 — Layer 4: Scoped Filesystem Access (3 min)

**SAY**: "The agent only sees what you mount — the workspace you handed it, and nothing else on the host. The workspace is read-write, because the agent has to edit code to be useful. But your home directory, your other projects, your SSH keys — none of it is mounted, so to the agent it simply doesn't exist."

```bash
# ▶ host-validate
# `sbx exec` runs in the workspace by default — and the workspace is writable
sbx exec demo-agent -- sh -c 'touch agent-can-write-here && pwd && ls agent-can-write-here'
```

**EXPECT**: The workspace's absolute path (the same path as on your host) and the new file listed — the agent **can** write here. In direct mode (the default) that file appears on your host instantly; that's exactly how the agent's edits and commits reach you. (Clean up: `rm agent-can-write-here`.)

```bash
# ▶ host-validate
# Now reach for something outside the workspace — your host home and its secrets.
# Substitute <you> with your real host username.
sbx exec demo-agent -- ls /Users/<you>/.ssh
```

**EXPECT**:

```
ls: cannot access '/Users/<you>/.ssh': No such file or directory
```

The agent isn't being *denied write access* to your SSH keys — it can't see them at all. The only host paths inside the sandbox are the workspace(s) you chose to mount.

---

**SAY**: "Scoped access. The agent writes to the workspace you gave it — that's the job. Everything else on your host was never mounted, so there's nothing to read, modify, or exfiltrate. And if you want to give it reference material it must *not* change, you mount that read-only:"

```bash
# Illustrative — mount extra context read-only by appending :ro (not run in this demo)
#   sbx run claude . /path/to/reference-docs:ro
```

**▸ Gov aside**: "Two controls. Per-run: you decide exactly which paths a sandbox mounts, and whether each is read-write or read-only (`:ro`). Org-wide: filesystem governance rules are an **allowlist of which host paths may be mounted at all** — they don't auto-mount anything into any sandbox. A path being 'allowed' in the Admin Console just means a developer is *permitted* to mount it; a sandbox still only ever gets the workspace(s) passed at launch. So an agent can never reach a path you didn't explicitly mount and the org didn't permit."

> **Reminder — `--clone` flips the write story:** In clone mode the agent works on a private clone *inside* the VM, with your host working tree mounted read-only (at `/run/sandbox/source`), so its writes never touch your host files. Its commits come back to you through the `sandbox-<name>` git remote instead.

---

## Beat 5 — Layer 5: Proxy-Managed Credentials (5 min)

**SAY**: "This is the one that surprises people most. The agent needs to call an API — but the API key never enters the VM. Let me show you."

```bash
# Inside the VM, the environment variable holds a decoy value — not the real key
sbx exec demo-agent -- sh -c 'echo $EXAMPLE_API_KEY'
```

**EXPECT**:

```
proxy-managed
```

```bash
# But the API call still works — the proxy intercepts the request
# and substitutes the real credential before it reaches the upstream
sbx run demo-agent -- --dangerously-skip-permissions \
  "Call the example API at api.example.com and show me the full response"
```

**EXPECT**: The agent reports a successful API response. The call went through even though the agent only ever saw `proxy-managed`.

```bash
# The proxy log shows the credential rewrite
sbx policy log
```

**EXPECT**: An entry for `api.example.com` showing the request was allowed and the `Authorization` header was rewritten.

---

**SAY**: "The agent sees `proxy-managed` — a literal placeholder string. The real API key lives in the host keychain. The proxy intercepts the outbound request, swaps in the real value, and the call succeeds. The agent never had the secret."

**▸ Gov aside**: "The credential never leaves the host OS keychain. An agent that's been compromised — or an agent that's been prompt-injected by malicious content in a repo — cannot exfiltrate your API keys by reading environment variables. There are no keys to steal. This is credential isolation by architecture, not by policy."

Now show where this behavior is declared:

```bash
# The serviceAuth block in spec.yaml is the complete policy
cat kits/cage-policy/spec.yaml
```

Point to the relevant sections:

- **`network.serviceDomains`** — maps `api.example.com` to the logical name `example`
- **`network.serviceAuth`** — tells the proxy to rewrite the `Authorization` header for that service
- **`credentials.sources`** — names the host-side env var (`EXAMPLE_API_KEY`) to read the real value from
- **`environment.proxyManaged`** — the list of variable names that get the `proxy-managed` decoy inside the VM

---

**SAY**: "And this whole policy is a file in git. It goes through code review. Your security team can audit exactly what an agent can reach and what credentials it can use — before the sandbox is created, not after an incident."

---

## Beat 6 — Governance Layer & Wrap-Up (2 min)

**SAY**: "Everything we've shown operates at the individual sandbox level. Org governance adds a layer above that — policy that applies to every sandbox in the org, set by security, not bypassable by individual developers."

```bash
# Show org-level policy — requires org governance to be configured
sbx policy ls
```

**EXPECT**: Active rules listed, including any org-level rules that override or supplement the kit-level spec. Inactive or suppressed rules appear with a note explaining why.

```bash
# Summary status of all sandboxes (agent, status, ports, workspace)
sbx ls
```

**EXPECT**: The `demo-agent` row shows the sandbox running, with its agent, workspace, and any published ports. (Network-policy and credential rewrites are shown by `sbx policy ls`, above.)

---

**SAY**: "Five layers: separate kernel, separate Docker, network cage, scoped filesystem access, and proxy-managed credentials. Each verifiable. Each auditable. Together they let you hand an AI agent the keys to your codebase without handing it the keys to your infrastructure."

**▸ Gov aside**: "Org governance is the sixth layer: policy-as-code that applies to every sandbox in your org, enforced by the proxy at the network level, not bypassable by individual developers changing their kit spec. It gives your security team a single control plane for the entire AI agent fleet."

---

**SAY**: "That's the standard demo. Add-on modules are ready depending on what this audience cares about most — check the README for the menu."

---

## Reset Between Runs

Run this after every demo to return to a clean state before the next session.

```bash
# Tear down the demo sandbox completely (prompts for confirmation; add --force to skip)
sbx rm demo-agent
```

Verify it's gone:

```bash
sbx ls
```

**EXPECT**: `demo-agent` no longer appears in the list, confirming the sandbox was removed.

If you need to reset network policy state that accumulated during the demo:

```bash
# Review and clear any demo-specific policy overrides
sbx policy ls
```

Remove any overrides added during Beat 3 before the next run.

---

## Add-On Modules

After Beat 6, pivot to one of the following depending on audience interest. Each is self-contained.

| Module | Audience Signal |
|---|---|
| **Golden Image** (`templates/golden/`) | "Who controls what's in the agent environment?" |
| **Ruff Linter Kit** (`kits/ruff-lint/`) | "How do you enforce coding standards across agents?" |
| **Voting App Live Edit** (`services/`) | "Can you show the agent actually doing something useful?" |
| **Org Policy Deep Dive** | "Walk me through how security sets the guardrails." |

---

## Validation Status

| Beat | Status | Notes |
|---|---|---|
| Beat 0 — Prep & Context | Validated live | Repo structure is stable |
| Beat 1 — Separate Kernel | Validated live | `uname -srm` shows Darwin (host) vs Linux (sandbox); command updated from `uname -r` |
| Beat 2 — Own Docker Engine | Validated live | Separate `docker ps` inventories confirmed |
| Beat 3 — Default-Deny Network | Representative (updated) | Allowlist-source step changed to `sbx policy ls`; the 403 + policy-log flow is unchanged. Re-run to confirm output |
| Beat 4 — Scoped Filesystem Access | Representative (updated) | Rewritten after docs review: the workspace is **read-write**; non-mounted host paths return `No such file or directory` (there is no `/host` read-only mount). Re-run on host to confirm exact paths/output |
| Beat 5 — Proxy-Managed Credentials | Representative | Documented from original validated run; `api.example.com` must be reachable per policy |
| Beat 6 — Governance & Wrap-Up | Representative | Org governance commands require org-level policy to be pre-configured |

> **Representative** beats follow the documented flow exactly and have been validated in controlled conditions. **Representative (updated)** beats were revised after a docs/CLI review (Beats 3 and 4) and their new commands/outputs have not yet been re-run live — confirm them on a host before presenting. All require the named prerequisites in place (org governance configured, `EXAMPLE_API_KEY` set) and may need a dry run if conditions change between demo dates.
