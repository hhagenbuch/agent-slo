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
- **The proving slice** (in progress) wires one SLI end to end: scheduled
  eval runs against a deployed agent → pass rate as an OTel metric → a
  `SloPolicy` check in the operator → `promotionsFrozen` → a PromptVersion
  refused on kind, with a GIF of the refusal.

Every signal in the RFC comes from a system that already ships:

| Signal | Shipped by |
|---|---|
| Honesty assertions (queued-not-sent, declined-not-hallucinated) | [castaway](https://github.com/hhagenbuch/castaway) + [agent-evals](https://github.com/hhagenbuch/agent-evals) judge tier |
| Trajectories and tool-call evidence | [agent-blackbox](https://github.com/hhagenbuch/agent-blackbox) |
| Cost per session (`agent.cost_usd`), and the SLI metrics themselves | [agent-meter](https://github.com/hhagenbuch/agent-meter) |
| Eval runs, pass rate, CI gating | [agent-evals](https://github.com/hhagenbuch/agent-evals) |
| Enforcement point (canary, eval gate, approval, rollback... and now freeze) | [agent-operator](https://github.com/hhagenbuch/agent-operator) |

## Status / roadmap

- [x] RFC: all five sections, reviewed like code (see the RFC PR)
- [ ] Proving slice: continuous eval pass rate wired end to end
- [ ] Freeze demonstrated on kind (refused while frozen, accepted after
      recovery, exempt fix passes the freeze but not the gate)
- [ ] Demo GIF of the refusal
- [ ] Roadmap (RFC-only until proven): honesty sampling pipeline, discipline
      rate aggregation over traces, cost SLI, the full enforcement ladder

## Part of a platform

This repo is the SLO layer of a set of agent-infrastructure projects built on
[spring-ai-agent-starter](https://github.com/hhagenbuch/spring-ai-agent-starter);
the method behind them is documented in the
[agent-engineering-playbook](https://github.com/hhagenbuch/agent-engineering-playbook).
