# sbx Enterprise Demo

A polished, end-to-end demo for **Docker Sandboxes (`sbx`)** — the tool that runs AI coding agents inside isolated microVMs with separate kernels, default-deny networking, read-only host filesystem access, and proxy-managed credentials that never enter the VM.

---

## How to use this repo

**Beats 1–6 are the spine** — a 23-minute live proof of five isolation layers that works for any audience. Run that first.

The **four add-on modules** are independently runnable segments you toggle per audience. Each takes 5–15 minutes. Mix and match; none depends on another.

```
./demo.sh prep   # pre-flight check: tools, sandbox creation, service validation
./demo.sh check  # mid-demo sanity check
./demo.sh reset  # clean slate between runs
```

---

## Module Menu

| # | Module | Audience | Use when… | Link |
|---|--------|----------|-----------|------|
| 0 | **Standard Demo** — Five isolation layers (beats 0–6) | Everyone | Always run this — it's the backbone of the pitch | [RUNBOOK.md](./RUNBOOK.md) |
| 1 | Clone Fleet — Parallel agents on one repo | Dev champions, eng managers | Audience wants to see parallel AI agents coding simultaneously | [addons/01-clone-fleet.md](./addons/01-clone-fleet.md) |
| 2 | Kit-as-Code — Policy as reviewable `spec.yaml` | CISOs, security architects | Audience asks "how do we audit what agents can reach?" | [addons/02-kit-as-code.md](./addons/02-kit-as-code.md) |
| 3 | Golden Template — Hardened org base image | Platform engineering, security | Audience asks "how do we enforce a baseline across all agents?" | [addons/03-golden-template.md](./addons/03-golden-template.md) |
| 4 | Dev-Velocity Kits — Stacked mixins + Git URL load | Developer advocates, platform teams | Audience wants composability and reproducibility for developer workflows | [addons/04-dev-velocity-kits.md](./addons/04-dev-velocity-kits.md) |

---

## Repo structure

```
sbx-enterprise-demo/
├── README.md                        ← you are here (module menu)
├── RUNBOOK.md                       ← standard demo, beats 0–6
├── POLICIES.md                      ← network + credential policy reference
├── demo.sh                          ← prep / check / reset lifecycle helper
├── services/
│   ├── vote/       (Python/Flask)   ← vote service — used in clone-fleet add-on
│   ├── result/     (Node.js)        ← results display service
│   └── gateway/    (Go)             ← API gateway routing between services
├── addons/
│   ├── 01-clone-fleet.md            ← [Dev]      parallel agents on one repo
│   ├── 02-kit-as-code.md            ← [Security] cage policy as code
│   ├── 03-golden-template.md        ← [Security] hardened org base image
│   └── 04-dev-velocity-kits.md      ← [Dev]      stacked kits + Git URL load
├── kits/
│   ├── cage-policy/spec.yaml        ← mixin: network allowlist + credential injection
│   └── ruff-lint/                   ← mixin: ruff linter + shared ruff.toml
│       ├── spec.yaml
│       └── files/workspace/ruff.toml
└── templates/
    └── golden/                      ← Docker image: enterprise-hardened sbx base
        ├── Dockerfile
        ├── build.sh
        └── corp-ca.crt              ← placeholder — replace with your real CA cert
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| `sbx` CLI | Follow the Docker Sandboxes setup guide |
| `gh` CLI | `brew install gh` / [cli.github.com](https://cli.github.com) |
| `docker` | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| `go` ≥ 1.22 | [go.dev/dl](https://go.dev/dl) |
| `node` ≥ 20 | [nodejs.org](https://nodejs.org) |
| `python3` ≥ 3.11 | system or [python.org](https://python.org) |

---

## Quick-start (standard demo only)

```bash
# 1. Clone
git clone https://github.com/nickorefice/sbx-enterprise-demo
cd sbx-enterprise-demo

# 2. Pre-flight
./demo.sh prep

# 3. Present beats 0–6
open RUNBOOK.md   # or cat it; it's a presenter script

# 4. Clean up after the demo
./demo.sh reset
```

---

## Validation status

Self-validated (actually executed when authoring this repo):
- `go build ./...` (gateway) — **self-validated**
- `node --check server.js` (result) — **self-validated**
- `python3 -m py_compile app.py` (vote) — **self-validated**
- `python3 -c "import yaml; yaml.safe_load(...)"` on both `kits/*/spec.yaml` — **self-validated** (well-formed YAML)
- `DRY_RUN=1 bash templates/golden/build.sh` (golden template `docker build`) — **self-validated** (image builds; `gh 2.50.0` and `ruff 0.4.10` verified inside the image)
- All internal Markdown links resolve to existing files — **self-validated**

Every step that requires a live `sbx` environment (`sbx run`, `sbx create`, `sbx kit validate`, registry push) is marked **▶ host-validate** in the runbook and add-on docs. Those steps were authored from the sbx specification and validated patterns; they have not been run inside this sandbox (sbx cannot run nested inside sbx).

---

## Contributing

Open a PR. The kit files (`kits/*/spec.yaml`) are the most likely things to update as sbx evolves. Keep the add-on docs self-contained so a presenter can print any single one and run it cold.
