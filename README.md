# agent-slo

**Behavioral SLOs for LLM agents: error budgets for honesty, tool discipline,
and cost... where budget burn freezes prompt promotions.**

Your agent has an uptime SLO. Why doesn't it have an honesty SLO?

## What this repo is (honestly)

**An RFC plus one proving slice.** This is a design-first project: the
document is the deliverable, and the code exists to prove the design's longest
path is real, not to claim a finished platform.

- **[The RFC](docs/RFC.md)** defines four behavioral SLIs (honesty rate,
  tool-discipline rate, cost-per-task, continuous eval pass rate), SLO
  targets with explicit error-budget math, a sampling design that is honest
  about what small windows can support, and an enforcement ladder that ends
  in the operator freezing prompt promotions when the budget is spent.
- **The proving slice** wires one SLI end to end: eval runs against a deployed
  agent → pass rate as an OTel metric (via agent-meter's SLI instruments) → a
  `SloPolicy` check in the operator → `promotionsFrozen` → a PromptVersion
  refused on kind, recovering by itself when the window rolls clean.

![The refusal: budget exhausted, promotions frozen, a feature PromptVersion parked at phase Frozen while an slo-exempt fix passes the freeze](slice/demo.gif)

Every signal in the RFC comes from a system that already ships:

| Signal | Shipped by |
|---|---|
| Honesty assertions (queued-not-sent, declined-not-hallucinated) | [castaway](https://github.com/hhagenbuch/castaway) + [agent-evals](https://github.com/hhagenbuch/agent-evals) judge tier |
| Trajectories and tool-call evidence | [agent-blackbox](https://github.com/hhagenbuch/agent-blackbox) |
| Cost per session (`agent.cost_usd`), and the SLI metrics themselves | [agent-meter](https://github.com/hhagenbuch/agent-meter) |
| Eval runs, pass rate, CI gating | [agent-evals](https://github.com/hhagenbuch/agent-evals) |
| Enforcement point (canary, eval gate, approval, rollback... and now freeze) | [agent-operator](https://github.com/hhagenbuch/agent-operator) |

## Run the slice

```bash
# siblings required: ../agent-operator ../spring-ai-agent-starter ../agent-evals ../agent-meter
export ANTHROPIC_API_KEY=sk-ant-...   # full mode: evals run against the real deployed starter
hack/e2e-kind.sh

# no key? run the keyless control-plane proof explicitly:
E2E_MODE=mechanics hack/e2e-kind.sh
```

The e2e walks the whole loop and asserts each step: an under-sampled window
does **not** act (minimum-evidence rule), four degraded runs exhaust the budget
and trip `promotionsFrozen`, a feature PromptVersion parks at phase `Frozen`,
an `slo-exempt: fix` version passes the **freeze** but still runs the **gate**,
steady runs roll the window clean, the freeze lifts with hysteresis, and the
parked version proceeds with no human action. It also asserts the metric leg:
an OTel collector must actually receive `agent.sli.eval_cases` and
`agent.sli.eval_pass_rate`.

**Two modes, and which one to trust:**

- **`mechanics`** (no key) is the **authoritative, deterministic proof.** Sample
  generation targets the runner's built-in `echo` target, so every control-plane
  assertion is reproducible: the whole loop is real, and the gate (which needs a
  real key to pass) proves itself by *refusing* the exempt fix. This is the run
  CI should trust.
- **`full`** (with a key) is a **fuller, best-effort live slice.** It runs the
  same loop against the real deployed starter with real evals, and ends in the
  exempt fix `Promoted` and the parked version promoted after recovery. It is
  best-effort because the promotion gate is a *live* eval: the operator's pinned
  `agent-evals:0.1.0` image predates that runner's cold-start/transient retry
  ([agent-evals #30](https://github.com/hhagenbuch/agent-evals/pull/30)), so a
  single gate case can transiently error under the eval Job's concurrent load.
  The slice's gate therefore tolerates one flake (`minPassRate 0.6`, i.e. 2 of 3
  deterministic checks clear it); the proper fix is bumping the operator's eval
  image to one that carries the retry.

Full mode is a *better slice*, not a production platform — the deterministic
guarantee lives in `mechanics`.

**Slice wiring note:** the operator reads samples from a ConfigMap
(`<agent>-slo-samples`), which is the slice's control path; the RFC's §4
production path (Prometheus query over the OTel series) is roadmap. Both legs
exist in the slice — the ConfigMap decides, the OTel series witnesses.

## Status / roadmap

- [x] RFC: all five sections, reviewed like code (see the RFC PR)
- [x] Proving slice: continuous eval pass rate wired end to end
      (runner → samples + OTel metrics → SloPolicy → freeze → refusal → recovery)
- [x] Freeze demonstrated on kind: refused while frozen, proceeds by itself
      after recovery, exempt fix passes the freeze but not the gate
- [x] Demo GIF of the refusal
- [x] Full-mode e2e against a real model (best-effort; see mode notes above)
- [ ] Bump the operator's in-cluster eval image to one with the cold-start
      retry (agent-evals #30) so the live gate needs no flake tolerance
- [ ] SloPolicy reads the SLI from Prometheus (RFC §4 production path) instead
      of the samples ConfigMap
- [ ] Roadmap (RFC-only until proven): honesty sampling pipeline, discipline
      rate aggregation over traces, cost SLI, the full enforcement ladder

## Part of a platform

This repo is the SLO layer of a set of agent-infrastructure projects built on
[spring-ai-agent-starter](https://github.com/hhagenbuch/spring-ai-agent-starter);
the method behind them is documented in the
[agent-engineering-playbook](https://github.com/hhagenbuch/agent-engineering-playbook).
