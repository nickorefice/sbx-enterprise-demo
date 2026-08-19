# Add-on 05 — Sandbox Breakout Defense: Anatomy of a Network-Isolation Bypass  [Security · Advanced]

**Goal**: Take a *real, published* class of AI-agent sandbox escape — the two network-isolation bypasses found in Anthropic Claude Code's own in-process sandbox (**CVE-2025-66479** and the **SOCKS5 hostname null-byte injection**) — and prove, live, that the same techniques are **contained** when the agent runs inside `sbx`. The punchline writes itself: the researcher's own "how should this have been defended" checklist is a description of the sbx architecture.

**Audience**: CISOs, security architects, red teams, AI-security specialists, and any technical buyer who has read the headlines ("Claude Code sandbox bypassed — twice") and wants to know why running the same agent inside `sbx` changes the outcome. This is the **advanced** module — run it *after* the standard demo (RUNBOOK Beats 0–6), because it builds on Beat 3 (default-deny network) and Beat 5 (proxy-managed credentials).

**Runtime**: ~12–15 min.

---

> ### Attribution & honesty
> The techniques demonstrated here were discovered and responsibly disclosed by **Aonan Guan** (Lead Cloud & AI Security, Wyze Labs). Credit is his; we are standing on his research to show a defensive architecture.
> - *Second Time, Same Sandbox* (SOCKS5 null-byte bypass): `https://oddguan.com/blog/second-time-same-sandbox-anthropic-claude-code-network-allowlist-bypass-data-exfiltration/`
> - *CVE-2025-66479* recap: `https://oddguan.com` → Blog
>
> **This module does not claim sbx's egress proxy is provably immune to every possible parser differential.** No allowlist implementation can claim that — which is exactly the researcher's closing point: *"treat a vendor's network allowlist as defense-in-depth, not as a boundary."* What we prove is narrower and stronger: (1) the *specific* bypass primitives from this research are **absent or rejected** in sbx, and (2) even if egress were bypassed, sbx removes the **payoff** — there are no live credentials in the box and no route to your intranet — which is the defense-in-depth the researcher says *"none is a feature of Claude Code."* In sbx it is.

---

## Prerequisites

- Everything from RUNBOOK Beat 0 (the `demo-agent` sandbox created in Beat 1). If you have not run the standard demo, create it now: `sbx create --name demo-agent claude .`
- The sandbox must have `curl` and `python3` (the default `claude` agent image ships both — verify with `sbx exec demo-agent -- sh -c 'command -v curl python3'`).
- At least one **allowlisted** domain your org policy permits, for the "allowed still works" control and the suffix-smuggle test. Defaults in the script are `github.com`; override with `ALLOWED_HOST` / `ALLOWED_SUFFIX` if your demo org allows a different domain.
- No network changes are required and nothing is written — the probe only makes outbound attempts and reads environment variables.

---

## Background — what actually broke, and why it matters

Claude Code shipped a **network sandbox** for its BashTool in October 2025. Its job: pin the agent to an allowlist so a prompt-injected agent can't phone home. Two independent outside reviews each returned a **complete bypass**:

| | Finding 1 — CVE-2025-66479 | Finding 2 — SOCKS5 null-byte injection |
|---|---|---|
| **Class** | Configuration-semantics bug | Parser differential (CWE-158 / CWE-436) |
| **Trigger** | User wrote `allowedDomains: []` meaning *"block everything"* | User wrote a wildcard allowlist, e.g. `*.google.com` |
| **Mechanism** | Check was `allowedDomains.length > 0`; an empty array → `false` → **proxy silently disabled** → allow-all | Attacker sends hostname `attacker.com\x00.google.com`. JS `endsWith('.google.com')` → **allow**; libc `getaddrinfo` truncates at `\x00` → dials `attacker.com` |
| **Result** | "Allow nothing" was read as "allow everything" | Any wildcard allowlist defeated with one null byte |

**The shared root cause** is architectural: Claude Code's sandbox runs *in-process* and delegates egress decisions to a **SOCKS5 proxy on the host** (`@pondwader/socks5-server` via `sandbox-runtime`) that had **no canonicalization at the trust boundary** between the JavaScript matcher and the libc resolver. Every release from GA (v2.0.24, 2025-10-20) through v2.1.89 was bypassable — ~130 versions, ~5.5 months, no CVE for Claude Code itself, no advisory, no changelog note. As the researcher put it: *"The user with a broken sandbox thinks they have a boundary."*

### The pivotal quote — the attacker specced our product

From the writeup's *"Whose job is it to keep credentials out of these agents?"*:

> *"An outer sandbox the agent cannot see or influence: a disposable VM, a container with no IAM role, a network namespace with no route to your intranet… Credential hygiene: no long-lived API keys on developer laptops where an agent can read them… Network egress controls outside the agent… plus audit logs that capture SOCKS-mediated traffic, not just HTTP. **Any one of these would have contained this bypass. None is a feature of Claude Code.**"*

Every item on that list **is** a feature of `sbx`. That is the whole module.

---

## Threat model → sbx control

| Attack primitive from the research | sbx control that neutralizes it | Proven in |
|---|---|---|
| Misread config flips allowlist to allow-all (Finding 1) | Egress is **default-deny at the host proxy**, not an in-agent library toggled by a settings flag. There is no "empty allowlist disables the proxy" code path. | Beat A |
| SOCKS5 CONNECT is the exfil transport (Finding 2) | sbx egress is an **HTTP-CONNECT forward proxy**; **no SOCKS5 endpoint** is exposed to the agent. The reproducer has nothing to connect to. | Beat B |
| Null-byte / encoding differential at the policy/resolver seam | sbx's proxy **rejects malformed authorities** (null byte, `%00`) with `400` before matching — the `isValidHost()` canonicalization the researcher said "should have existed from GA." | Beat C |
| Exfiltrate creds: model key, GitHub token, `~/.aws`, `~/.config/gh` | **Credentials are never in the VM** — injected by the proxy on the wire. The agent sees empty/decoy values; the sensitive dirs aren't mounted. | Beat D |
| Reach cloud metadata `169.254.169.254`, intranet | The microVM has **no route** to those; the proxy denies them by default. | Beat D |
| Egress that basic HTTP logs miss | Every attempt — allowed or blocked — is in the **proxy audit log** (`sbx policy log`). | Beat E |

---

## Quick run (the whole story in 30 seconds)

If you want the headline before the walk-through, run the bundled probe **inside** the sandbox. It executes each published technique against the sandbox's own egress boundary and prints a contained/bypassed scorecard.

```bash
# Runs the probes from inside demo-agent against its own proxy.
# Override ALLOWED_HOST/ALLOWED_SUFFIX with a domain your org policy allows.
sbx exec -w "$(pwd)" demo-agent -- env ALLOWED_HOST=github.com ALLOWED_SUFFIX=github.com \
  bash addons/breakout.sh
```

**EXPECT**: a section-by-section report ending in `Result: 10 contained, 0 bypassed` (exit 0). Then walk the beats below to explain *why* each one is contained — that's where the value is for a security audience.

---

## Beat A — There is no "allow-all" footgun (defeats Finding 1)

**SAY**: "The first bypass wasn't exotic. A user wrote `allowedDomains: []` — the most restrictive setting the docs offered — and the sandbox read it as 'no allowlist, so allow everything.' The floor fell through. Watch the floor in sbx."

```bash
# A host with no allow rule — under default-deny it is blocked, period.
sbx exec demo-agent -- curl -sS -o /dev/null -w 'example.com -> HTTP %{http_code}\n' \
  --max-time 10 https://example.com
```

**EXPECT**: `example.com -> HTTP 403`. There is no configuration — empty, malformed, or absent — that turns default-deny into allow-all. Egress is denied by the **host proxy** unless an org rule explicitly allows it; "no rule" means "no egress," the opposite of the Claude Code failure.

**▸ Gov aside**: "In Claude Code, the allowlist lived in the agent's own `settings.json` and was enforced by a library in the agent's process. A parsing quirk in that library disabled the whole boundary. In sbx the boundary is **outside** the agent — a proxy on the host, governed by org policy the agent can't read or rewrite. There's no in-agent flag whose misparse can switch it off."

---

## Beat B — The exploit's transport doesn't exist here (defeats Finding 2's delivery)

**SAY**: "The second bypass is a SOCKS5 trick. It needs a SOCKS5 proxy to talk to — that's the channel Claude Code handed the agent. Let's see what egress channel sbx hands the agent."

```bash
# What proxying is exposed to the agent?
sbx exec demo-agent -- sh -c 'echo "HTTPS_PROXY=$HTTPS_PROXY"; echo "ALL_PROXY=${ALL_PROXY:-<unset>}"; env | grep -i socks || echo "no SOCKS endpoint"'
```

**EXPECT**:

```
HTTPS_PROXY=http://gateway.docker.internal:3128
ALL_PROXY=<unset>
no SOCKS endpoint
```

The agent's egress is an **HTTP-CONNECT** forward proxy. There is no `ALL_PROXY`, no `socks5h://` endpoint — so the null-byte reproducer (`net.connect` to a SOCKS5 server) has nothing to connect to. The specific attack surface the research targeted is simply not present.

**▸ Gov aside**: "This isn't luck — it's a different architecture. Claude Code delegated egress to a third-party SOCKS5 server (`@pondwader/socks5-server`: 10 GitHub stars, last commit mid-2024) running with full host network privileges. sbx's egress boundary is the platform proxy, not a niche dependency bundled into the agent runtime."

---

## Beat C — Canonicalization at the trust boundary (defeats the parser differential itself)

**SAY**: "Suppose the agent tries the *idea* behind the null-byte attack against sbx's proxy anyway — glue a blocked host in front of an allowed suffix with a null byte, betting the allow-checker and the resolver disagree. Let's send that raw."

```bash
# Raw CONNECT with a real null byte, and the percent-encoded variant.
sbx exec demo-agent -- python3 - <<'PY'
import os,socket,re
proxy=os.environ["HTTPS_PROXY"]; host,port=re.sub(r'^https?://','',proxy).split(":")
for spec in ["example.com\x00.github.com:443", "example.com%00.github.com:443"]:
    s=socket.create_connection((host,int(port)),timeout=10)
    s.sendall((f"CONNECT {spec} HTTP/1.1\r\nHost: x\r\n\r\n").encode("latin-1"))
    print(repr(spec), "->", s.recv(200).split(b"\r\n")[0].decode("latin-1","replace")); s.close()
PY
```

**EXPECT**:

```
'example.com\x00.github.com:443' -> HTTP/1.1 400 Bad Request
'example.com%00.github.com:443' -> HTTP/1.1 400 Bad Request
```

The proxy **rejects the malformed authority outright** — it never reaches a suffix match, so there is no allow/resolve disagreement to exploit. This is precisely the `isValidHost()` seam (reject `\x00`, `%`, CRLF, non-DNS characters *before* matching) that the fix in `sandbox-runtime` 0.0.43 added — and that sbx enforces at its own boundary.

Now show that even a *legal-looking* suffix trick doesn't reach the blocked host, because sbx enforces policy on the **real destination** (its proxy terminates and inspects TLS), not on a string the agent supplied:

```bash
sbx exec demo-agent -- curl -sS -o /dev/null -w 'suffix-smuggle -> HTTP %{http_code}\n' \
  --max-time 10 'https://example.com..github.com/'
```

**EXPECT**: `suffix-smuggle -> HTTP 403`. The dressed-up hostname never opens a channel to `example.com`.

**▸ Gov aside**: "The whole bug class is 'two layers parse the same bytes differently.' The defense is to canonicalize at the seam and enforce on the resolved destination, not on agent-supplied text. sbx does both. But be honest with your buyer: we're not claiming a parser is unbreakable forever — we're claiming the boundary is in the right place, and that's why the next beat matters."

---

## Beat D — Even a bypass has nothing to steal (defense-in-depth)

**SAY**: "Here's the part that survives *any* future egress bug. Assume the worst — assume someone finds a new differential tomorrow and opens a channel. What does the agent actually have to send? In Claude Code the answer was: the model API key, the GitHub token it authenticated with, `~/.aws`, `~/.config/gh`. In sbx?"

```bash
sbx exec demo-agent -- sh -c '
  echo "ANTHROPIC_API_KEY=[$ANTHROPIC_API_KEY]"
  echo "GH_TOKEN=$GH_TOKEN"
  ls -d ~/.aws ~/.config/gh 2>&1 | sed "s/^/  /"
'
```

**EXPECT**:

```
ANTHROPIC_API_KEY=[]
GH_TOKEN=gho_sbxproxymanaged000000000000000000000
  ls: cannot access '/home/agent/.aws': No such file or directory
  ls: cannot access '/home/agent/.config/gh': No such file or directory
```

The model key is **empty** (the proxy injects the real one on the wire — RUNBOOK Beat 5). The GitHub token is a **decoy placeholder** (`gho_sbxproxymanaged…`), not a real credential — yet `git push` still works, because the proxy swaps the real token in on requests to GitHub. The credential directories the writeup names as prime targets **aren't mounted**. And the metadata endpoint attackers pivot through is unreachable:

```bash
sbx exec demo-agent -- curl -sS -o /dev/null -w 'IMDS -> HTTP %{http_code}\n' \
  --max-time 6 http://169.254.169.254/latest/meta-data/
```

**EXPECT**: `IMDS -> HTTP 403`.

**▸ Gov aside**: "This is the researcher's 'credential hygiene' and 'network with no route to your intranet' — the layers he says *would have contained the bypass* and that *aren't features of Claude Code*. In sbx they're the default. The exfiltration channel and the exfiltration payload are two separate controls; sbx removes both."

---

## Beat E — It's all in the audit log (the control the writeup says HTTP logs miss)

**SAY**: "One more from his remediation list: 'audit logs that capture SOCKS-mediated traffic, not just HTTP.' Everything we just tried — allowed and blocked — is on the record."

```bash
sbx policy log
```

**EXPECT**: a **Blocked requests** section listing `example.com` (and the metadata IP) with hit counts and timestamps, and an **Allowed requests** section showing legitimate traffic (e.g. `api.anthropic.com`, `github.com`). Every probe from this module appears here — the audit trail the researcher says most deployments lack.

**▸ Gov aside**: "Egress decisions are made and logged at the platform layer, not inside the agent that might be compromised. Your SOC gets a single, tamper-distant record of what every agent tried to reach — which is where incident response actually starts."

---

## Land it

**SAY**: "Two outside reviews, two complete bypasses of an in-agent sandbox — the researcher's own conclusion was 'treat the vendor allowlist as defense-in-depth, not the boundary,' and then he listed the layers that would have contained it: an outer sandbox the agent can't influence, credentials off the box, egress control outside the agent, real audit logs. That list is the sbx architecture. We didn't design it in response to this research — this research describes what sbx already is. You don't have to trust that any single allowlist parser is perfect. You put the boundary where a parser bug can't cash out."

---

## Reset

Nothing to undo — this module writes nothing and changes no policy. If you created `demo-agent` solely for this add-on, tear it down:

```bash
sbx rm demo-agent
```

---

## Validation status

| Beat | Status | Notes |
|---|---|---|
| Quick-run probe (`addons/breakout.sh`) | **Validated live** | Run inside a live `sbx` sandbox (`SANDBOX_NAME=demo`, sbx proxy `gateway.docker.internal:3128`): `10 contained, 0 bypassed`, exit 0 |
| Beat A — no allow-all footgun | **Validated live** | `curl https://example.com` → HTTP 403 under default-deny |
| Beat B — no SOCKS5 transport | **Validated live** | `ALL_PROXY` unset, no `socks5` env; egress is `HTTPS_PROXY=http://gateway.docker.internal:3128` |
| Beat C — canonicalization at the seam | **Validated live** | Raw `CONNECT` with real `\x00` and with `%00` → **HTTP/1.1 400 Bad Request**; suffix-smuggle `example.com..<allowed>` end-to-end → **403** (never dials the blocked host) |
| Beat D — nothing to exfiltrate | **Validated live** | `ANTHROPIC_API_KEY` empty; `GH_TOKEN=gho_sbxproxymanaged000…` (decoy); `~/.aws` and `~/.config/gh` absent; `169.254.169.254` → **403** |
| Beat E — audit log | Authored from the documented `sbx policy log` format (see RUNBOOK Beat 3, validated there on sbx v0.38) | Confirm the split Blocked/Allowed sections during rehearsal |

> The mechanism-level probes in Beats A–D were **executed against a live sbx egress proxy from inside a running sandbox** while authoring this module. The `sbx exec demo-agent -- …` wrappers reproduce those exact probes through the presenter's own sandbox; run the quick-run script once during rehearsal so the scorecard and phrasing are familiar. `ALLOWED_HOST`/`ALLOWED_SUFFIX` default to `github.com`; set them to a domain your demo org explicitly allows if `github.com` is not on your allowlist.
