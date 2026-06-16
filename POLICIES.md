# Network and Credential Policies

This document describes the security model enforced by the `cage-policy` mixin and the surrounding
sandbox infrastructure. It is intended for security engineers, platform teams, and reviewers who
need to understand what traffic an agent sandbox is permitted to initiate and how credentials are
delivered without exposing them to agent code.

---

## 1. Default-Deny Network Model

Every sandbox created through the `sbx` CLI operates under a **default-deny outbound policy**.
Unless a domain appears on an explicit allowlist, all TCP connections originating inside the
sandbox are rejected at the proxy layer before they reach the network. HTTP and HTTPS requests
that are blocked receive an HTTP 403 response whose body identifies the blocking rule and its
origin (kit-level, org-level, or system-level policy).

This approach inverts the conventional model — rather than blocking known-bad destinations, only
known-good destinations are reachable. The practical effect is that an agent operating inside the
sandbox cannot exfiltrate data to an arbitrary third-party host, cannot pull tooling from untrusted
package mirrors, and cannot communicate with attacker-controlled infrastructure even if it is
prompted or otherwise induced to attempt it.

The policy is enforced transparently at the proxy level: the agent process inside the VM sees
ordinary TCP connection failures for disallowed destinations and does not receive any signal that a
policy layer (as opposed to a routing failure) caused the refusal.

---

## 2. Allowed Domains (`kits/cage-policy/spec.yaml`)

The `cage-policy` mixin declares its allowlist under `network.allowedDomains`. Each entry is
justified below.

| Domain | Purpose | Rationale |
|---|---|---|
| `api.anthropic.com` | Claude API | Claude Code agents must be able to reach the Anthropic API to receive instructions and return results. Blocking this domain would render the agent non-functional. |
| `github.com` | Source control (HTTPS Git, web) | The primary use-case of the demo is for the agent to read and write code in a GitHub repository. `git push`, `git fetch`, and `gh` CLI operations all connect here. |
| `api.github.com` | GitHub REST and GraphQL API | The `gh` CLI uses the REST API to open pull requests, query issue trackers, and inspect CI status. Without this domain the agent cannot complete tasks that involve PR workflows. |
| `objects.githubusercontent.com` | GitHub LFS and release assets | Large binary objects (LFS pointers, release tarballs) are served from this CDN rather than `github.com` itself. Go module proxies that resolve GitHub-hosted modules may also pull from here. |
| `registry-1.docker.io` | Docker Hub image registry | The demo services (`vote`, `result`, `gateway`) may be built and run as containers during the agent's task execution. Pulling base images requires access to Docker Hub's primary registry API endpoint. |
| `production.cloudflare.docker.com` | Docker Hub CDN (layer blobs) | Docker Hub stores image layer blobs on Cloudflare's CDN. Even when `registry-1.docker.io` is reachable, layer pulls will fail unless this CDN domain is also allowed. |

### Denied Domains (Explicit Denylist)

The following domains are explicitly denied even if a broader allowlist rule would otherwise permit
them. Explicit denials take precedence over the allowlist.

| Domain Pattern | Reason |
|---|---|
| `*.dropbox.com` | Consumer cloud-storage services are a common exfiltration vector. An agent must not be able to upload repository contents or secrets to Dropbox. |
| `*.wetransfer.com` | Same rationale as Dropbox. WeTransfer provides unauthenticated large-file transfer and is frequently abused for data exfiltration. |
| `pastebin.com` | Pastebin is used to exfiltrate text data (credentials, source code) and to host second-stage payloads. Blocking it removes both attack surfaces. |

---

## 3. Proxy-Managed Credential Model

Credentials are never written into the VM image and are never visible as their real values inside
the sandbox. The delivery chain works as follows.

### 3.1 Host Keychain → Sandbox Secret Store

On the host, an operator stores the real credential in the `sbx` secret store:

```bash
sbx secret set <sandbox-name> example -t "$(printenv EXAMPLE_API_KEY)"
```

This writes the token into the host-side secret store. The token is associated with the logical
service name `example` (matching the `serviceDomains` and `serviceAuth` configuration in
`spec.yaml`).

### 3.2 VM Decoy Value

When the sandbox starts, the proxy sets the environment variable `EXAMPLE_API_KEY` inside the VM
to the literal string `proxy-managed`. This is declared explicitly in `spec.yaml`:

```yaml
environment:
  proxyManaged:
    - EXAMPLE_API_KEY
```

If the agent or any process running inside the VM reads this environment variable — through shell
expansion, `os.getenv()`, `process.env`, or any other mechanism — it receives `proxy-managed`, not
the real token. There is no path by which the actual credential value can be observed from inside
the VM.

### 3.3 Proxy Rewrite on Outbound Request

When the agent makes an outbound HTTPS request to a domain listed under `serviceDomains`
(in this demo, `api.example.com`), the proxy intercepts the request before it leaves the host
network stack. It looks up the credential associated with the mapped service name (`example`),
reads the real token from the host secret store, and rewrites the request header specified by
`serviceAuth`:

```yaml
serviceAuth:
  example:
    headerName: Authorization
    valueFormat: "Bearer %s"
```

The outbound request that reaches `api.example.com` carries a correctly formed
`Authorization: Bearer <real-token>` header. The agent process never constructed that header with
the real value; the proxy injected it transparently.

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

## 4. Governance vs Kit-Level Policy

### Kit-Level Policy (Team Intent)

The `network` block in `kits/cage-policy/spec.yaml` represents a team's stated intent for what
network access their sandboxes need. It is reviewable as source code — any change to the allowlist
goes through a pull request and is subject to normal code review.

This is valuable: it creates a human-readable, version-controlled record of why each domain is
permitted, and it prevents accidental scope creep from ad-hoc `sbx policy allow` invocations
that never get documented.

### Org-Level Governance (Real Enforcement Boundary)

When an organization enables sandbox governance, org administrators define network rules at the
org level through the `sbx` control plane. **Org-level rules take precedence over kit-level
network declarations.**

This means:

- A kit that declares `allowedDomains: ["*"]` cannot bypass an org-level domain restriction.
- A kit that allows `api.example.com` will have that allowance silently narrowed if the org policy
  does not permit that domain.
- Conversely, an org-level allowance does not automatically propagate into kits; kits still need
  to declare their required domains so that the least-privilege principle is respected per sandbox.

In a governed organization the correct mental model is:

```
effective_allowlist = kit_allowlist ∩ org_allowlist
effective_denylist  = kit_denylist  ∪ org_denylist
```

The kit policy serves as documentation and as a least-privilege declaration. The org policy is the
actual enforcement boundary that cannot be overridden by agent activity or kit configuration.

### Practical Guidance for Reviewers

When reviewing a kit that adds domains to `allowedDomains`:

1. Confirm the org-level policy would permit the domain before assuming the kit allowance is
   effective.
2. Treat the kit's `allowedDomains` list as a maximum — sandboxes using the kit will receive
   access to at most those domains, subject to further restriction by org policy.
3. Any domain added to a kit's allowlist should be accompanied by a comment explaining the
   business justification, as shown in `kits/cage-policy/spec.yaml`.

---

## 5. Auditing

The `sbx` CLI exposes two commands for inspecting network policy state and connection history.

### 5.1 `sbx policy ls` — Active Rules

```bash
sbx policy ls
```

Lists every rule currently active for the sandbox, including its origin (kit, org, or system), its
type (allow or deny), and whether it is suppressed by a higher-priority rule. Example output:

```
RULE                                    TYPE    ORIGIN    STATUS
api.anthropic.com                       allow   kit       active
github.com                              allow   kit       active
api.github.com                          allow   kit       active
objects.githubusercontent.com           allow   kit       active
registry-1.docker.io                    allow   kit       active
production.cloudflare.docker.com        allow   kit       active
*.dropbox.com                           deny    kit       active
*.wetransfer.com                        deny    kit       active
pastebin.com                            deny    kit       active
api.example.com                         allow   kit       active (credential-rewrite)
suspicious-domain.example.net           allow   kit       SUPPRESSED by org deny
```

A `SUPPRESSED` status indicates the kit rule exists but org policy has overridden it — useful for
identifying kit rules that are not having their intended effect.

### 5.2 `sbx policy log` — Connection History

```bash
sbx policy log
```

Shows recent outbound connection attempts with their outcome. Useful for confirming that a service
the agent needs is reachable, and for diagnosing unexpected blocks. Example output:

```
TIMESTAMP            HOST                                    RULE                        RESULT
2026-06-16T14:01:03  api.anthropic.com                       kit:allow                   allowed
2026-06-16T14:01:04  api.github.com                          kit:allow                   allowed
2026-06-16T14:01:07  api.example.com                         kit:allow (credential-rewrite) allowed
2026-06-16T14:02:11  evil.exfil.example.net                  default-deny                blocked
2026-06-16T14:02:45  www.dropbox.com                         kit:deny (*.dropbox.com)    blocked
```

The `RULE` column identifies which rule produced the outcome. For blocks, the `RESULT` will be
`blocked` and the rule column will identify either an explicit deny entry or `default-deny`
(meaning no allow rule matched).

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
| *(absent)* | Default-deny; domain has no matching allow rule | Add domain to kit allowlist if legitimate; escalate to org admin if org-level permit is needed |
| `local policy` | Explicit kit-level deny rule matched | Review kit `deniedDomains`; override via `sbx policy allow <domain>` if access is legitimate |
| `corporate policy` | Org-level rule is blocking the domain | Contact your platform or security team — this cannot be overridden at the kit or sandbox level |
| `system policy` | System-enforced rule | Contact your infrastructure team |

---

## 6. References

- Kit source: `kits/cage-policy/spec.yaml`
- Sandbox CLI reference: `sbx --help`
- Org governance documentation: consult your organization's `sbx` admin panel
