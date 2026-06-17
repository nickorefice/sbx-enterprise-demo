# Add-on 02 — Kit-as-Code: Credential Injection  [Security]

**Goal**: Show that an agent's service credentials are injected by the proxy and declared as reviewable code in `spec.yaml` — the real secret stays in the host keychain, never enters the VM, and the agent only ever sees the decoy string `proxy-managed`.

**Audience**: CISOs, security architects, compliance engineers — anyone who needs to answer "how do agents authenticate to our services without the secret leaking into agent-readable space?"

---

## Prerequisites

- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally (`github.com/nickorefice/sbx-enterprise-demo`)
- `python3` available locally (for the YAML-lint fallback in Step 2)
- Optional: `EXAMPLE_API_KEY` set as a sandbox secret (`sbx secret set <sandbox> example -t "<value>"`) to demonstrate credential injection end-to-end

---

## Background

In sbx, a **kit** (mixin) is a directory containing a `spec.yaml` that declaratively describes an agent's capabilities. This module focuses on the **credential model** — the security crown jewel:

- The real secret stays in the **host keychain**.
- `credentials.sources.<svc>.env` tells the proxy which host-side variable holds it.
- `environment.proxyManaged` sets the in-VM variable to the decoy string `proxy-managed`.
- `network.serviceDomains` + `network.serviceAuth` tell the proxy which upstream to attach the credential to, and how (which header, what format).

The agent authenticates to the service, but never possesses the token.

> **Why are there no network allow/deny rules in this kit?**
> In a governed enterprise, **org-level governance owns network and filesystem access and overrides any kit network rules** (see the box at the end of this doc). A network allowlist declared in a kit is therefore noise in the environments these buyers actually run — it's documentation at best, silently overridden at worst. So we keep this kit focused on what it uniquely provides, and on what org governance does *not* manage: **credential injection**. For the network cage itself, see RUNBOOK Beat 3 (default-deny network) and your org governance policy.

---

## Step 1: Show the Credential Model as Code

```bash
# The entire credential-injection contract lives here — in git, reviewable like any other code
cat kits/cage-policy/spec.yaml
```

Walk through each section with the audience:

| Section | What it does |
|---------|-------------|
| `credentials.sources.example.env` | Names the **host-side** env var (`EXAMPLE_API_KEY`) that holds the real secret. The proxy reads it at request time; it is never written into the VM. |
| `environment.proxyManaged` | Sets `EXAMPLE_API_KEY=proxy-managed` **inside** the VM — the agent never sees the real value |
| `network.serviceDomains` | Maps `api.example.com` to the logical service name `example` so a credential can be attached to it |
| `network.serviceAuth` | Rewrites the `Authorization` header on every outbound request to that service, as `Bearer <real-token>` |

**SAY**: "This is the credential contract for the agent, in a file that goes through pull request review, gets scanned by your SAST tools, and lives in your git history. The real token is in the host keychain. The kit only declares *where to read it* and *which service to attach it to* — never the value itself."

**SAY**: "Notice what is *not* here: there's no network allowlist. In your org, network and filesystem access are governed centrally and override anything a kit could declare — so we don't pretend the kit is the network boundary. The kit injects credentials; org governance is the cage."

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

This confirms the file is parseable but does not validate the sbx schema. Use it only when demonstrating on a machine without the sbx CLI installed.

---

## Step 3: Apply the Kit and Prove the Credential Decoy

Launch an agent with the kit and ask it to reveal the API key:

```bash
# ▶ host-validate
sbx run claude --kit ./kits/cage-policy \
  -- --dangerously-skip-permissions \
  "Print the value of the EXAMPLE_API_KEY environment variable"
```

**EXPECT**: The agent prints `proxy-managed` — not a real key.

**SAY**: "The agent cannot leak a secret it never received. The proxy holds the real token and substitutes it on outbound requests to `api.example.com`. Inside the VM, `EXAMPLE_API_KEY` is the literal string `proxy-managed`. Even if a prompt-injection attack instructs the agent to exfiltrate credentials, there is nothing to exfiltrate."

---

## Step 4: Prove the Proxy Rewrite (credential reaches the service)

Show that, despite the decoy, authenticated calls to the mapped service still succeed — the proxy injects the real `Authorization` header on the way out:

```bash
# ▶ host-validate — requires EXAMPLE_API_KEY set as a sandbox secret
sbx run claude --kit ./kits/cage-policy \
  -- --dangerously-skip-permissions \
  "curl -s -o /dev/null -w '%{http_code}' https://api.example.com/whoami and report the status code and whether you sent any Authorization header yourself"
```

**EXPECT**: The request is authenticated (the service accepts it) even though the agent never set an `Authorization` header — the proxy rewrote it using the real token from the host secret store.

**SAY**: "Decoy inside the VM, real token on the wire. The agent made an authenticated call without ever holding the credential. That's the whole game: the secret is usable but not observable."

---

## Step 5: Show the Audit Trail

After Steps 3 and 4, inspect the connection log:

```bash
# ▶ host-validate (run after steps 3-4, while the sandbox still exists)
sbx policy log
```

**EXPECT**: A table showing each domain the sandbox attempted to contact, the rule matched, and the last-seen timestamp — including `api.example.com` (allowed, credential-rewrite) and `api.anthropic.com` (Claude API traffic).

**SAY**: "This is your runtime audit log. Every outbound connection attempt, allowed or denied, timestamped — and credential use is mediated by the proxy, which logs the service name and destination without ever logging the token itself. Pair this with your SIEM and you have full observability over agent network *and* credential behavior."

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
> | Credential injection (this kit) | `kits/cage-policy/spec.yaml` | Team / platform |
>
> Credential injection is *not* part of org governance, so it correctly belongs in the kit. The network cage *is*, so it belongs at the org level. See `POLICIES.md` for the full model.

---

**SAY for CISO audience**: "Git history IS your audit log for credential-injection changes. Who wired which service to which secret, when, and why — it's all in the commit, reviewed like any other code, with CODEOWNERS gating the `kits/` directory. The enforcement mechanism is the proxy; the governance mechanism for the network cage is your org policy; the governance mechanism for credential wiring is your existing git workflow."

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Show spec.yaml | Self-validated (file read) | No sbx CLI required |
| Step 2A — `sbx kit validate` | **host-validate** | Requires sbx CLI |
| Step 2B — YAML lint | Self-validated (python3) | Fallback if sbx unavailable |
| Step 3 — Credential decoy | **host-validate** | Requires sbx CLI |
| Step 4 — Proxy rewrite | **host-validate** | Requires sbx CLI; set `EXAMPLE_API_KEY` secret and a reachable `api.example.com` (or substitute a real service) |
| Step 5 — Audit trail (`sbx policy log`) | **host-validate** | Run while sandbox still exists |
