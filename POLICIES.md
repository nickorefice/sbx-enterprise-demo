# Network and Credential Policies

This document describes the sandbox security model: what traffic an agent sandbox is permitted to
initiate (governed at the **org** level) and how credentials are delivered without exposing them to
agent code (configured host-side via the **secret store**, `sbx secret set-custom`). It is intended for
security engineers, platform teams, and reviewers.

> **Division of responsibility (read this first):**
> - **Network and filesystem access** are owned by **org-level governance** (Docker Admin Console /
>   Governance API). When governance is active it **replaces** any kit- or sandbox-local rules.
> - **Credential injection** is configured **host-side** in the secret store (`sbx secret set-custom`).
>   The value, its target host, and its in-VM placeholder never enter the kit or git; the proxy reads
>   the real value on the host and swaps it onto outbound requests.
>
> The kits in this repo therefore declare **no** network allow/deny rules — in a governed org they
> would be silently overridden noise. The network model below describes what to configure in **org
> governance**.

---

## 1. Default-Deny Network Model

Every sandbox created through the `sbx` CLI operates under a **default-deny outbound policy**.
Unless a domain appears on an explicit allowlist, all TCP connections originating inside the
sandbox are rejected at the proxy layer before they reach the network. HTTP and HTTPS requests
that are blocked receive an HTTP 403 response whose body identifies the blocking rule and its
origin (org-level or system-level policy).

This approach inverts the conventional model — rather than blocking known-bad destinations, only
known-good destinations are reachable. The practical effect is that an agent operating inside the
sandbox cannot exfiltrate data to an arbitrary third-party host, cannot pull tooling from untrusted
package mirrors, and cannot communicate with attacker-controlled infrastructure even if it is
prompted or otherwise induced to attempt it.

The policy is enforced transparently at the proxy level: the agent process inside the VM sees
ordinary TCP connection failures for disallowed destinations and does not receive any signal that a
policy layer (as opposed to a routing failure) caused the refusal.

The standard demo proves this live in **RUNBOOK Beat 3**.

---

## 2. Network Access Is Governed at the Org Level

Network access is **not** declared in a kit in this repo. In a governed organization, org rules
replace kit network rules entirely, so a kit allowlist is at best documentation and at worst a
false sense of enforcement. Configure the allowlist in **org governance** (Docker Admin Console or
Governance API) so it applies uniformly to every sandbox and cannot be overridden locally.

### 2.1 Recommended Org Allowlist for these demo services

The following is the set of domains a Claude Code agent working in this repo typically needs. Use it
as the starting point for the **org-level** allowlist — not as a kit declaration.

| Domain | Purpose | Rationale |
|---|---|---|
| `api.anthropic.com` | Claude API | Claude Code agents must reach the Anthropic API to receive instructions and return results. Blocking this renders the agent non-functional. |
| `github.com` | Source control (HTTPS Git, web) | The agent reads and writes code in a GitHub repository. `git push`, `git fetch`, and `gh` CLI operations connect here. |
| `api.github.com` | GitHub REST/GraphQL API | The `gh` CLI uses the REST API to open pull requests, query issues, and inspect CI status. |
| `objects.githubusercontent.com` | GitHub LFS and release assets | LFS pointers and release tarballs are served from this CDN. Go module proxies resolving GitHub-hosted modules may also pull from here. |
| `registry-1.docker.io` | Docker Hub image registry | The demo services may be built and run as containers; pulling base images requires Docker Hub's registry API endpoint. |
| `production.cloudflare.docker.com` | Docker Hub CDN (layer blobs) | Image layer blobs are served from Cloudflare's CDN; layer pulls fail without it even when `registry-1.docker.io` is reachable. |
| `pypi.org`, `files.pythonhosted.org`, `astral.sh` | Python tooling | Needed only if a kit installs Python tooling at runtime (e.g. `ruff-lint`). Sidestep entirely by pre-baking tools into the golden template (add-on 03). |

### 2.2 Egress to Avoid

Consumer file-sharing and paste services are common exfiltration vectors and should be denied at the
org level (or simply excluded from the allowlist under default-deny): `*.dropbox.com`,
`*.wetransfer.com`, `pastebin.com`, and similar.

---

## 3. Proxy-Managed Credential Model (`sbx secret set-custom`)

Credentials are never written into the VM image and are never visible as their real values inside the
sandbox. The value, the target host, and the in-VM placeholder are all configured **host-side** — none
of it lives in the kit or in git. The delivery chain works as follows.

### 3.1 Host Secret Store (set once on the host)

On the host, an operator registers the credential as a custom secret:

```bash
sbx secret set-custom -g \
  --host api.example.com \
  --env EXAMPLE_API_KEY \
  --placeholder proxy-managed \
  --value "$(printenv EXAMPLE_API_KEY)"
```

This records, in the host-side secret store: the real `--value` (which never leaves the host), the
`--host`(s) the proxy should rewrite, the `--env` var to expose inside the VM, and the `--placeholder`
the VM sees in its place. It appears in a dedicated **CUSTOM SECRETS** section of `sbx secret ls` and
applies live to running sandboxes.

### 3.2 VM Decoy Value

When the sandbox starts, the env var `EXAMPLE_API_KEY` inside the VM is set to the placeholder string
`proxy-managed` (the `--placeholder` value; omit the flag and sbx generates one like `sbx-cs-<rand>`).

If the agent or any process inside the VM reads this variable — through shell expansion, `os.getenv()`,
`process.env`, or any other mechanism — it receives `proxy-managed`, not the real token. There is no
path by which the actual credential value can be observed from inside the VM.

### 3.3 Proxy Rewrite on Outbound Request

When the agent makes an outbound request to one of the configured `--host` targets (in this demo,
`api.example.com`), the proxy intercepts it before it leaves the host network stack, finds the
placeholder anywhere in the request, and replaces it with the real value from the host secret store.
The request that reaches `api.example.com` carries the correctly formed
`Authorization: Bearer <real-token>` header (or the real value wherever the placeholder appeared). The
agent process never constructed that header with the real value; the proxy injected it transparently.

> Note: this is **credential plumbing**, not a network cage — it tells the proxy *which upstream* to
> attach the credential to. It does not allow or deny traffic; egress remains governed by org policy.

### 3.4 Security Properties

This model provides several meaningful guarantees:

- **No secret-in-image risk.** The VM filesystem and memory never contain the real credential. A
  full memory dump of the sandbox process would yield only `proxy-managed`.
- **No prompt-injection exfiltration.** Even if a malicious document or web page instructs the
  agent to print the value of `EXAMPLE_API_KEY`, the agent can only report the decoy string.
- **Auditability.** Every credential use is mediated by the proxy, which can log service-name,
  timestamp, and destination without logging the token itself.
- **Rotation without rebuild.** Updating the credential in the host secret store takes effect
  immediately on the next outbound request; no sandbox rebuild or image repush is required.

---

## 4. Org Governance vs Kit Scope

| Concern | Where it lives | Owner | Overridable by a kit? |
|---|---|---|---|
| Network egress (allow/deny) | Org governance (Admin Console / API) | Security / IT | No — org rules replace kit/local rules |
| Filesystem access (mountable host paths) | Org governance | Security / IT | No |
| Credential injection (value, target host, placeholder) | Host secret store (`sbx secret set-custom`) | Security / platform | N/A — org governance does not manage credentials |
| Tooling, config files, agent instructions | Kits (e.g. `secure-baseline`, `ruff-lint`) | Team / platform | N/A |

When organization governance is active, the documentation is explicit: "local rules are no longer
evaluated and can't be used to supplement or override the organization policy." This is why the
network cage belongs at the org level and credential material belongs in the host secret store — each
is owned where it is actually enforced. Changes to the org allowlist go through org-level review;
credential changes are made with `sbx secret set-custom` and audited in the secret store; and the
non-secret kit goes through pull-request review on the `kits/` directory (gate it with CODEOWNERS).

---

## 5. Auditing

The `sbx` CLI exposes two commands for inspecting network policy state and connection history.

### 5.1 `sbx policy ls` — Active Rules

```bash
sbx policy ls
```

Lists every rule currently active for the sandbox, including its origin (org or system) and type
(allow or deny). In a governed org, network rules show `org` as their origin:

```
RULE                                    TYPE    ORIGIN    STATUS
api.anthropic.com                       allow   org       active
github.com                              allow   org       active
api.github.com                          allow   org       active
registry-1.docker.io                    allow   org       active
*.dropbox.com                           deny    org       active
api.example.com                         allow   org       active (credential-rewrite via custom secret)
```

The `credential-rewrite` annotation on `api.example.com` reflects the custom secret's host mapping
(`sbx secret set-custom --host`); the allow itself is an org-level decision.

### 5.2 `sbx policy log` — Connection History

```bash
sbx policy log
```

Shows recent outbound connection attempts with their outcome. Useful for confirming that a service
the agent needs is reachable, and for diagnosing unexpected blocks. Example output:

```
TIMESTAMP            HOST                                    RULE                        RESULT
2026-06-16T14:01:03  api.anthropic.com                       org:allow                   allowed
2026-06-16T14:01:04  api.github.com                          org:allow                   allowed
2026-06-16T14:01:07  api.example.com                         org:allow (cred-rewrite)    allowed
2026-06-16T14:02:11  evil.exfil.example.net                  default-deny                blocked
2026-06-16T14:02:45  www.dropbox.com                         org:deny (*.dropbox.com)    blocked
```

The `RULE` column identifies which rule produced the outcome. For blocks, the rule column identifies
either an explicit deny entry or `default-deny` (meaning no allow rule matched).

### 5.3 Interpreting Blocks

A blocked request response body contains structured information:

```
Blocked by network policy: domain <host>
  rule:   "<rule-name>" (domain, deny)
  origin: <origin>
  detail: <explanation>
```

| `origin` value | Meaning | Recommended action |
|---|---|---|
| *(absent)* | Default-deny; domain has no matching allow rule | Add the domain to the **org** allowlist if legitimate |
| `corporate policy` / `org` | Org-level rule is allowing/blocking the domain | Adjust the rule in the Admin Console or Governance API — it cannot be overridden at the kit or sandbox level |
| `system policy` | System-enforced rule | Contact your infrastructure team |

---

## 6. References

- Credential config (host-side): `sbx secret set-custom --help`
- Non-secret kit source: `kits/secure-baseline/spec.yaml`
- Sandbox CLI reference: `sbx --help`
- Org governance: Docker Admin Console / Governance API (`docs.docker.com/ai/sandboxes/governance/`)
