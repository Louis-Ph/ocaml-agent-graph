# Demonstration Scenarios

This folder is a home for scenario packs built on top of `ocaml-agent-graph`.

Each scenario folder is meant to stay structured and reusable.

Recommended shape:

```text
scenario_name/
  README.md
  scenario.json
  prompts/
  scoring/
  output/
```

The idea is simple:

- `scenario.json` defines the mission
- `prompts/` defines what each LLM role should do
- `scoring/` defines how decisions are ranked
- `output/` defines the expected deliverable

Current scenario packs:

- `adaptive_webcrawler`: real search + crawl + LLM reflection with tight token budgets
- `professional_buyer`: real-LLM procurement crawler and best-offer selector
- `multi_supplier_rfq`: compare quotes from several suppliers and produce a buyer memo
- `price_watch`: monitor a shortlist of products and flag a buy window
- `category_restock_optimizer`: decide when and where to reorder based on cost and supply risk

These folders are intentionally scenario-first.
They describe workflows that can later be turned into executable binaries,
benchmarks, or orchestration graphs without mixing all concerns together.
