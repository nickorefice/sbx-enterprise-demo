# Add-on 02 — Kit-as-Code for the Cage  [Security]

**Goal**: Show that the network perimeter and credential injection for every agent are declared as reviewable code in `spec.yaml` — not click-ops UI, not undocumented secrets.

**Audience**: CISOs, security architects, compliance engineers, anyone who needs to answer "how do we audit what agents can access?"

---

## Prerequisites

- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally (`github.com/nickorefice/sbx-enterprise-demo`)
- `python3` available locally (for the YAML-lint fallback in Step 2)
- Optional: `EXAMPLE_API_KEY` set as a sandbox secret (`sbx secret set <sandbox> example -t "<value>"`) to demonstrate credential injection

---

## Background

In sbx, a **kit** (also called a mixin) is a directory containing a `spec.yaml` that declaratively describes:

- **Network policy** — which domains an agent may reach (allowlist) and which are blocked (denylist)
- **Credential injection** — which secrets flow into the sandbox and in what form
- **Environment variables** — what the agent sees (vs. what the proxy substitutes at request time)
- **Installed tools and startup commands**
- **agentContext** — instructions injected into the agent's system prompt at startup

Because a kit is a directory of files in a git repository, every change goes through pull request review, is scanned by your existing SAST tools, and is preserved in your git history. There is no separate policy UI to screenshot, no out-of-band change to track.

---

## Step 1: Show the Policy as Code

```bash
# The entire network cage lives here — in git, reviewable like any other code
cat kits/cage-policy/spec.yaml
```

Walk through each section with the audience:

| Section | What it does |
|---------|-------------|
| `network.allowedDomains` | Explicit allowlist — only these domains pass through the proxy |
| `network.deniedDomains` | Overrides the allowlist — `*.dropbox.com` is blocked even if something else would allow it |
| `network.serviceDomains` | Groups a domain behind a logical service name for credential attachment |
| `network.serviceAuth` | Rewrites the `Authorization` header on every outbound request to the mapped domain |
| `credentials.sources` | Tells the proxy which host-side env var holds the real secret |
| `environment.proxyManaged` | Sets `EXAMPLE_API_KEY=proxy-managed` inside the VM — the agent never sees the real value |

**SAY**: "This is your entire network policy for this agent. Allowlist. Denylist. Credential injection. All in a file that goes through pull request review, gets scanned by your SAST tools, and lives in your git history. Not a click-ops UI somewhere."

**SAY**: "When a security engineer asks 'can the agent reach Dropbox?' the answer is in the file, in the PR that last changed it, with the reviewer's name attached."

---

## Step 2: Validate the Kit Structure

**Option A — sbx CLI validation (preferred):**

```bash
# ▶ host-validate (requires sbx CLI)
sbx kit validate ./kits/cage-policy
```

**EXPECT**: `kit is valid` or equivalent success output. Any schema violations print as structured errors.

**Option B — YAML lint fallback (if sbx CLI is unavailable):**

```bash
# Self-validate: at minimum the file is well-formed YAML
python3 -c "import yaml; yaml.safe_load(open('kits/cage-policy/spec.yaml')); print('YAML OK')"
```

**EXPECT**: `YAML OK`

This confirms the file is parseable but does not validate the sbx schema. Use this only when demonstrating on a machine without the sbx CLI installed.

---

## Step 3: Apply the Kit and Prove the Credential Decoy

Launch an agent with the cage-policy kit and ask it to reveal the API key:

```bash
# ▶ host-validate
sbx run claude --kit ./kits/cage-policy \
  -- --dangerously-skip-permissions \
  "Print the value of the EXAMPLE_API_KEY environment variable"
```

**EXPECT**: The agent prints `proxy-managed` — not a real key.

**SAY**: "The agent cannot leak a secret it never received. The proxy holds the real token and substitutes it on outbound requests to `api.example.com`. Inside the VM, `EXAMPLE_API_KEY` is the literal string `proxy-managed`. Even if the agent were instructed to exfiltrate credentials, there is nothing to exfiltrate."

---

## Step 4: Prove the Network Cage

Ask the agent to reach a domain on the denylist:

```bash
# ▶ host-validate
sbx run claude --kit ./kits/cage-policy \
  -- --dangerously-skip-permissions \
  "Try to curl https://dropbox.com and report what happens"
```

**EXPECT**: The agent reports a connection error or HTTP 403. The proxy returns a structured block message:

```
Blocked by network policy: domain dropbox.com
  rule:   "*.dropbox.com" (domain, deny)
  origin: local policy
  detail: domain matched explicit deny rule
```

**SAY**: "The deny rule in `spec.yaml` line 26 — `*.dropbox.com` — produced that block. It is not a firewall rule buried in a network appliance config. It is a line of text in a file your team owns, reviewed, and merged."

---

## Step 5: Show the Audit Trail

After Steps 3 and 4, inspect the connection log:

```bash
# ▶ host-validate (run after steps 3-4, while the sandbox still exists)
sbx policy log
```

**EXPECT**: A table showing each domain the sandbox attempted to contact, the rule matched, and the last-seen timestamp. You will see:

- `api.anthropic.com` — allowed (Claude API traffic from the agent itself)
- `dropbox.com` — denied (your Step 4 test)
- Any other domains the agent contacted while completing the task

**SAY**: "This is your runtime audit log. Every outbound connection attempt, allowed or denied, timestamped. Pair this with your SIEM — `sbx policy log` can export JSON — and you have full observability over agent network behavior."

---

> **IMPORTANT — Org Governance and Kit Scope**
>
> Under active org-level governance, **org network rules override the `network:` block in this kit**. If your org policy denies a domain, the kit's allowlist cannot override it. If your org policy allows a domain, the kit cannot block it with a deny rule.
>
> The kit serves two purposes in a governed org:
> 1. **Team-level documentation of intent** — "we intend this agent to reach only these domains"
> 2. **Additional restriction** — the kit can narrow the org-permitted set further, but cannot widen it
>
> The org policy is the actual enforcement boundary. This distinction matters for audit: org-level changes require org-level review; kit-level changes require team-level review.

---

**SAY for CISO audience**: "Git history IS your audit log for policy changes. Who changed the allowlist, when, and why — it's all in the commit. Your security team reviews it like any other code change. You can require CODEOWNERS approval on the `kits/` directory, block merges without a security team sign-off, and scan the YAML with existing policy-as-code tools. The enforcement mechanism is the proxy; the governance mechanism is your existing git workflow."

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Show spec.yaml | Self-validated (file read) | No sbx CLI required |
| Step 2A — `sbx kit validate` | **host-validate** | Requires sbx CLI |
| Step 2B — YAML lint | Self-validated (python3) | Fallback if sbx unavailable |
| Step 3 — Credential decoy | **host-validate** | Requires sbx CLI; set `EXAMPLE_API_KEY` secret for full demo |
| Step 4 — Network cage | **host-validate** | Requires sbx CLI |
| Step 5 — Audit trail (`sbx policy log`) | **host-validate** | Run while sandbox still exists |
