# Demonstration Scenarios

Every demo is runnable in three ways:

1. **Shell**: `./demos/<name>/run.sh` or `./demos/<name>/run.sh "your custom query"`
2. **Human terminal**: type the query directly, or use `/run demos/<name>/run.sh`
3. **Messenger**: send the query to your Telegram/WhatsApp bot (requires `scripts/start-with-messengers.sh`)

## Demos

### adaptive_webcrawler

Real web search + crawl + LLM reflection. The swarm scouts the web,
extracts content, reflects on coverage gaps, and refines its queries
until the evidence is convincing.

```bash
./demos/adaptive_webcrawler/run.sh
./demos/adaptive_webcrawler/run.sh "Find sources about Kubernetes multi-agent orchestration"
```

From the human terminal:

```text
/run demos/adaptive_webcrawler/run.sh "Find sources about effect handlers"
```

From Telegram/WhatsApp (via the messenger stack):

> Search the web for authoritative sources about OCaml 5 effect handlers

### professional_buyer

End-to-end procurement workflow. The swarm plans a sourcing strategy,
analyzes the market, scores offers, and writes a professional buyer memo
with ranked alternatives and cost breakdowns.

```bash
./demos/professional_buyer/run.sh
./demos/professional_buyer/run.sh "Find the best deal on industrial servo motors"
```

From the human terminal:

```text
You are a professional buyer. Find the best deal on stainless steel fasteners. Produce a buyer memo with sourcing brief, ranked alternatives, cost breakdown, and final recommendation.
```

### multi_supplier_rfq

Compare quotes from several suppliers and produce a buyer memo with
normalized comparison, commercial exceptions, and a recommendation.

```bash
./demos/multi_supplier_rfq/run.sh
./demos/multi_supplier_rfq/run.sh "Compare 3 suppliers for industrial bearings"
```

From the human terminal:

```text
Compare RFQ responses from three suppliers for stainless steel bolts. Normalize the quotes, list commercial exceptions, recommend a supplier, and explain the rationale.
```

### price_watch

Monitor a shortlist of products and flag a buy window when price and
supply conditions are favorable.

```bash
./demos/price_watch/run.sh
./demos/price_watch/run.sh "Track prices for NVIDIA H100 GPUs"
```

From the human terminal:

```text
Monitor current market prices for NVIDIA H100 GPUs. Produce a tracked offer table, price movement summary, and a buy-now-or-wait recommendation.
```

### category_restock_optimizer

Decide when and where to reorder based on cost, supplier risk, lead
time, and reorder urgency.

```bash
./demos/category_restock_optimizer/run.sh
./demos/category_restock_optimizer/run.sh "Optimize restock for industrial bearing category"
```

From the human terminal:

```text
Optimize category-level replenishment for industrial bearings. Balance price, reliability, lead time, and supplier risk. Produce a restock shortlist and reorder recommendation.
```

## How it works

Each `run.sh` pipes the scenario through the swarm graph via `call --kind=assistant`.
The adaptive_webcrawler has its own compiled binary with real web search and crawl
capabilities. The other demos use the general-purpose swarm (planner + discussion +
validator) with scenario-specific prompts.

From a messenger, the swarm spokesperson handles any text input. Just describe what
you want in natural language — the agents will plan, discuss, and synthesize an answer.
