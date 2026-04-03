# Adaptive Webcrawler

This scenario demonstrates a real webcrawler that behaves like a small swarm:

- scout agents search the web with real queries
- fetch agents retrieve live pages
- extractor agents turn noisy HTML into compact evidence
- a reflector LLM critiques coverage gaps and proposes refined queries
- the run stops only when the evidence looks convincing enough

The design goal is not "crawl everything".
The goal is "adapt quickly, spend few tokens, and converge on trustworthy sources".

## Default mission

The shipped scenario looks for authoritative and practical sources about
OCaml 5 effect handlers:

- at least one official source
- at least one hands-on or code-oriented source
- several distinct domains

## Cost control

The scenario is intentionally conservative:

- few rounds
- few pages per round
- small `gpt-5-mini` prompts
- only a handful of LLM calls

## Run

```sh
dune exec ./bin/adaptive_webcrawler_demo.exe
```

Override the objective at runtime:

```sh
dune exec ./bin/adaptive_webcrawler_demo.exe -- \
  --objective "Find authoritative and practical sources about OCaml effect handlers for scheduler composition."
```
