# Professional Buyer

This scenario pack describes a real procurement workflow powered by real LLMs
and a real web crawler.

The target behavior is not "find something cheap".
The target behavior is "act like a professional buyer".

That means:

- understand the need
- search the market
- collect offers from real pages
- normalize product facts
- compare total cost, not only sticker price
- reject weak or risky offers
- justify the final recommendation

## Core result

The final result should look like a buyer memo written by a procurement
professional:

- recommended article
- ranked alternatives
- total landed cost
- shipping and lead time
- warranty and seller quality
- risks and missing data
- why this is the best professional choice

## Expected workflow

```text
user need
  -> planning LLM
  -> crawler supervisor LLM
  -> real web crawl
  -> extraction / normalization LLM
  -> scoring and procurement decision LLM
  -> buyer memo
```

## Folder contents

- `scenario.json`: scenario contract
- `prompts/`: role prompts
- `scoring/`: weighted buyer scorecard
- `output/`: expected final report shape

## Important rule

The crawler must prefer:

- manufacturer pages
- major trusted retailers
- pages with explicit price, shipping, stock, and warranty information

The system should avoid making a strong recommendation from weak evidence.

