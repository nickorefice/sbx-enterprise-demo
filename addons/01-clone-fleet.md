# Add-on 01 — Clone Fleet  [Dev]

**Goal**: Launch three isolated agents simultaneously — one per service — watch them code in parallel, then merge all three branches in a single command.

**Audience**: Developers, engineering managers, anyone who wants to see what "parallel agents" actually looks like in practice.

---

## Prerequisites

- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally (`github.com/nickorefice/sbx-enterprise-demo`)
- Three terminal tabs or panes ready (tmux, iTerm2 split panes, or similar)
- `git` available locally (any recent version)
- No existing sandboxes named `svc-vote`, `svc-result`, or `svc-gateway` (`sbx list` to confirm)

---

## Background

When you launch `sbx run` with `--clone`, sbx:

1. Creates a fresh microVM with its own Linux kernel and Docker engine
2. Clones the repository into the VM (the host working tree is **not** mounted — no shared state)
3. Registers a `sandbox-<name>` remote on the **host** repo so you can `git fetch` the agent's commits when it finishes

Three sandboxes = three completely independent clones. They cannot see each other's files, cannot step on each other's branches, and cannot conflict. The only shared thing is the original commit they all cloned from.

---

## Prep (5 min)

Verify the three services each have room for the agent to add something meaningful:

```bash
# vote service — Python/Flask, currently has /healthz, /vote, /results
# Agent will add: /stats (vote percentages + timestamp)
grep -n "def " /path/to/sbx-enterprise-demo/services/vote/app.py

# result service — Node.js, currently has /healthz and HTML rendering
# Agent will add: uptime field to /healthz
grep -n "pathname" /path/to/sbx-enterprise-demo/services/result/server.js

# gateway — Go, currently proxies /vote and /results, has /healthz
# Agent will add: /metrics (aggregates upstream /healthz responses)
grep -n "HandleFunc" /path/to/sbx-enterprise-demo/services/gateway/main.go
```

If the endpoints already exist from a previous run, reset to a clean commit before proceeding (see **Step 4: Reset**).

---

## Step 1: Launch the Fleet

Open three terminal tabs. Run one command per tab. All three can be started in quick succession — they are independent and will run concurrently.

```bash
# Tab 1 — vote service agent
# ▶ host-validate
sbx run svc-vote --clone \
  -- --dangerously-skip-permissions \
  "In services/vote: add a /stats endpoint returning vote percentages and a timestamp, then commit 'fleet: vote stats endpoint'"
```

```bash
# Tab 2 — result service agent
# ▶ host-validate
sbx run svc-result --clone \
  -- --dangerously-skip-permissions \
  "In services/result: add /healthz returning {status:ok,uptime:<seconds>}, then commit 'fleet: result healthz uptime'"
```

```bash
# Tab 3 — gateway agent
# ▶ host-validate
sbx run svc-gateway --clone \
  -- --dangerously-skip-permissions \
  "In services/gateway: add a /metrics endpoint proxying both upstream /healthz responses into one JSON, then commit 'fleet: gateway metrics aggregation'"
```

**SAY**: "Three isolated agents, zero conflicts — they each get their own clone of the repo. While they work, let's review the architecture."

While the agents run, point the audience to the logs streaming in each tab. Each agent is independently reading its service's code, planning changes, writing code, and committing — with no awareness of the other two.

Expected runtime: 2–5 minutes per agent depending on code complexity. They will finish at slightly different times.

---

## Step 2: Review the Fleet's Work

Once all three tabs show a completed commit, fetch their branches back to your host:

```bash
# Fetch all three sandbox branches
git fetch sandbox-svc-vote
git fetch sandbox-svc-result
git fetch sandbox-svc-gateway
```

Label them locally for readability:

```bash
git branch fleet/vote    sandbox-svc-vote/main
git branch fleet/result  sandbox-svc-result/main
git branch fleet/gateway sandbox-svc-gateway/main
```

Visualize the divergent graph:

```bash
# See all three branches diverge from the same base commit
git log --oneline --graph --all --decorate | head -20
```

**EXPECT** output resembling:

```
* abc1234 (fleet/gateway) fleet: gateway metrics aggregation
| * def5678 (fleet/result) fleet: result healthz uptime
|/
| * ghi9012 (fleet/vote) fleet: vote stats endpoint
|/
* base0001 (HEAD -> main, origin/main) <last shared commit>
```

Inspect per-branch diff stats to see exactly what each agent changed:

```bash
git diff --stat main..fleet/vote
git diff --stat main..fleet/result
git diff --stat main..fleet/gateway
```

Optionally review individual file changes:

```bash
# What did the vote agent write?
git diff main..fleet/vote -- services/vote/app.py

# What did the gateway agent write?
git diff main..fleet/gateway -- services/gateway/main.go
```

---

## Step 3: Merge

**Option A — Octopus merge (one command, all three):**

```bash
git merge fleet/vote fleet/result fleet/gateway \
  --no-edit \
  -m "fleet merge: vote stats, result healthz, gateway metrics"
```

Git's octopus merge strategy handles three branches cleanly when the changes touch different files (which they do, since each agent worked in a different service directory). If it conflicts, fall back to Option B.

**Option B — Sequential review then merge:**

```bash
# Review and merge one at a time
git merge --no-ff fleet/vote   -m "merge: vote stats endpoint"
git merge --no-ff fleet/result -m "merge: result healthz uptime"
git merge --no-ff fleet/gateway -m "merge: gateway metrics aggregation"
```

**SAY**: "Three agents, three PRs worth of work, merged in one command. Each ran in total isolation — no shared filesystem, no shared branch, no coordination required between them."

---

## Step 4: Reset Between Runs

Clean up sandboxes and local tracking branches so the demo is ready to run again:

```bash
# Delete the sandboxes (stops the VMs, releases resources)
# ▶ host-validate
sbx delete svc-vote svc-result svc-gateway

# Remove local fleet branches
git branch -D fleet/vote fleet/result fleet/gateway 2>/dev/null || true

# Remove the sandbox remotes added by sbx
git remote remove sandbox-svc-vote    2>/dev/null || true
git remote remove sandbox-svc-result  2>/dev/null || true
git remote remove sandbox-svc-gateway 2>/dev/null || true
```

If you also want to undo the merge commit (to re-run the full demo from scratch):

```bash
# Revert the merge commit — creates a new "undo" commit, preserves history
git revert -m 1 HEAD
# Or if you prefer a hard reset (destructive — only on a demo branch):
# git reset --hard HEAD~1
```

---

## Real-World Notes

**Opening PRs instead of direct fetch**: In a real workflow, each agent would run `gh pr create` at the end of its task rather than just committing locally. You would review three PRs through your normal code review process. This demo uses direct branch fetch for visual clarity.

**Scaling further**: The same pattern works with 10 or 20 agents. Each gets its own sandbox VM, its own clone, its own isolated network. The host's git history is the single source of truth — agents contribute to it via fetch/PR, not by sharing a workspace.

**Audit trail**: After the run, inspect what each agent actually touched on the network:

```bash
# ▶ host-validate — run while sandboxes still exist, or immediately after sbx delete
sbx policy log
```

This shows every domain each sandbox contacted, the rule that allowed or denied it, and the last-seen timestamp.

---

## Security Note

Each sandbox runs in a microVM with a separate Linux kernel. There is no shared `/proc`, no shared network namespace, and no shared Docker daemon between `svc-vote`, `svc-result`, and `svc-gateway`. If one agent were compromised, it could not reach the others.

The default-deny network proxy means an agent cannot phone home to an attacker-controlled host unless that domain is explicitly on the allowlist. Use `sbx policy log` to verify the exact egress footprint of each agent after the run.

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Launch fleet | **host-validate** | Requires `sbx` CLI on host |
| Step 2 — Fetch and review | Self-validated (git local) | Runs entirely on host, no sbx needed |
| Step 3 — Merge | Self-validated (git local) | Runs entirely on host |
| Step 4 — Reset | **host-validate** (`sbx delete`) + self-validated (git local) | `sbx delete` requires host CLI |
| Security audit (`sbx policy log`) | **host-validate** | Run while sandboxes still exist |
