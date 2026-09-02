# 2. Chunking as token-bounded unit packing

## Status

Accepted, 2026-07-30. The worked example in Concept is superseded by
[ADR-0029](0029-chunk-partition-level-incremental-and-data-shape-guarantees.md); the
decision and its principles stand.

## Concept

**Chunking** is the step that turns long text into pieces small enough to embed and retrieve.
Embedding models and LLM context windows are bounded, so a 90-minute transcript or a 40-page
document must be broken up. The naive instinct is to cut the text every *N* characters, but a blind
cut mangles meaning, it splits a sentence, or a speaker's turn, right down the middle, and the
resulting embedding represents half a thought.

First, what does "embed" mean, since everything here depends on it? An **embedding** is a list of
numbers, known as a *vector*, that a model computes to capture the *meaning* of a piece of text, arranged so
that texts with similar meaning sit close together in that numeric space. Storing a chunk's embedding
is what later lets you find it by meaning rather than by keyword. Embeddings power every downstream
step (retrieval, knowledge bases), which is exactly why the *shape* of a chunk matters so much: a
chunk that fuses two unrelated thoughts embeds to a muddled point that sits near nothing useful, and
no amount of clever search recovers from a bad chunk. Chunking well is how you get embeddings worth
searching.

The better mental model is **packing, not cutting**. Think of it like packing sentences into
fixed-size boxes: you never tear a sentence in half to make it fit; you fill a box until the next
whole sentence wouldn't fit, then start a new box. The indivisible thing you pack is a **unit** like a
speaker turn in a transcript, or a sentence in a document. This keeps every chunk internally
coherent, and because the boundaries fall between units, the size limit is **soft** (a chunk can
overshoot by at most the one unit that tipped it over).

A worked example, packing turns into a 40-token budget (token ≈ `chars/4`):

```
turn 1 (18 tok)  ┐
turn 2 (17 tok)  ┘ chunk 1  (35 tok)   ← next turn (25) would exceed 40 → close the box
turn 3 (25 tok)  ┐
turn 4 (12 tok)  ┘ chunk 2  (37 tok)
turn 5 (30 tok)  → chunk 3  (30 tok)
```

> **Superseded by [ADR-0029](0029-chunk-partition-level-incremental-and-data-shape-guarantees.md)
> (draft).** The diagram above depicts greedy first-fit packing, closing a chunk before admitting
> the unit that would exceed the budget. The implementation has never done this. It assigns chunks
> with `floor(cum_before / step)`, which has no lookahead, so the unit that crosses a boundary joins
> the *current* chunk. The same five units produce two chunks of 61 and 43 tokens, both over budget,
> identically on all four engines. The principle the example illustrates is unchanged: the cap is
> soft because units are atomic. Only the packing it depicts is wrong. ADR-0029 records why the
> greedy form was not adopted instead.

## Context

Two use cases look like two features: "chunk a transcript" (split by turn) and "chunk a document"
(split prose into sentences). Chunking is also a genuine design question,
so the algorithm was designed and approved before implementation. Requirements: **deterministic**
(same input → same chunks, always), **zero-cost** (no AI call, it must be cheap enough to run over
everything), **portable** across engines, and it must **preserve lineage** (which source rows a
chunk came from, so a retrieval hit can cite its origin).

## Decision

Chunking is **one operation: pack ordered, atomic *units* into token-bounded chunks** that never
split a unit and never cross a partition key. A "unit" is one input row like a turn, or a sentence
produced by the layer-1 splitter `split_sentences`. The mechanism is pure window SQL, identical
on every engine:

1. estimate tokens per unit: `ceil(char_length / 4)` — no model call;
2. take a running sum of tokens over the ordered units within a partition (`SUM(...) OVER`);
3. assign a chunk number with `FLOOR(cumulative_tokens / target_tokens)`, densely ranked.

Every chunk carries `source_rows` (the ids it packed). A `partition_column` (e.g. `call_id`) means
chunks never span two calls. Optional overlap re-includes the boundary units of the previous chunk
so context isn't lost at the seams.

```sql
{{ dbt_context_engineering.chunk(
     relation=ref('utterances'), id_column='utterance_id',
     order_column='turn_index', text_column='text',
     partition_column='call_id', target_tokens=512) }}
-- → chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate
```

## Reasoning

**Why units must never be split.** Newcomers to retrieval usually ask "how many characters per
chunk?", which treats text as a byte stream. But an embedding is a lossy summary of *meaning*, and
meaning lives in whole thoughts. Cut a sentence in half and each half embeds to a vector that
represents neither the first idea nor the second; retrieval then surfaces a fragment that reads as a
non-sequitur, and the model reasoning over it is misled. So the founding principle is: never split
the atom of meaning (a sentence, a speaker turn). Everything else follows from that.

**Why the cap is therefore soft.** Once you commit to never splitting a unit, you *cannot* also
guarantee an exact token count because the last unit either fits or it doesn't. We reasoned that a soft
cap that always keeps thoughts whole beats a hard cap that sometimes severs one: the small overshoot
is harmless (models have headroom), a split thought is not. When two goals conflict, keep the one
that protects meaning.

**Why deterministic, zero-cost SQL instead of a smarter (semantic) chunker.** Two reasons rooted in
the discipline. First, chunking is the *widest* step in the pipeline and runs over everything, so
it must be nearly free; an AI call per boundary would cost more than the enrichment that follows it.
Second, chunking is *upstream of everything*: if it were non-deterministic, every downstream
embedding, retrieval, and test would become non-reproducible. Determinism at the top of the pipeline
is what makes the whole rest of it testable. We consciously traded the marginal quality of semantic
chunking for determinism and near-zero cost. We also left an escape hatch: anyone who truly needs
semantic boundaries can split upstream and feed the units in.

**Why lineage is mandatory, not optional.** In analytics we would never ship a fact table without
keys back to its source. Context is no different, except the stakes are higher, because an agent
will *cite* this context to a human. The moment a chunk forgets which turns or sentences it came
from, a retrieval hit becomes an unattributable claim. So `source_rows` is present from the very
first transformation and is carried all the way to the retrieved result; attribution is designed in,
not bolted on.

## Consequences

- One portable macro (`chunk`) covers both transcripts and documents; the only per-engine
  divergence is ordered array/string aggregation, isolated in `array_agg` / `string_agg`.
- `source_rows` lineage is non-negotiable and flows all the way into retrieval results downstream.
- The token estimate is a heuristic (`chars/4`), not a real tokenizer, done deliberately, to stay
  zero-cost and portable; it is close enough for budgeting.
- Sentence splitting is intentionally naive (`[.!?]`) and will over-split abbreviations; prose that
  needs better boundaries should be split upstream with a real tokenizer and fed to `chunk` as
  units.
- Fully deterministic, so it is the best-validated layer in the deterministic test suite
  (boundaries, the soft cap, lineage, and overlap are all asserted).

## Alternatives considered

- **Fixed-width character/token cutting.** Simplest, but splits units mid-thought and produces
  low-quality embeddings. Rejected.
- **Semantic / embedding-similarity chunking.** Higher quality in theory, but needs an AI call
  (cost, non-determinism) and is hard to make portable. Out of scope for the cheap, deterministic
  default; a user can always split upstream and feed units in.

## Glossary

- **Chunk / chunking** — a chunk is a bounded piece of text small enough to embed and retrieve;
  chunking is the step that produces them from long text.
- **Token** — the sub-word unit a language model actually reads and is billed in (roughly ¾ of a
  word, or ~4 characters of English; the word "chunking" is about 2 tokens). Because models can only
  accept so many tokens at once and charge per token, every text size in this package is measured in
  tokens, estimated cheaply as `chars / 4`.
- **Context window** — the maximum number of tokens a model can accept at once. Chunks must fit
  inside it (with room to spare for the prompt and the answer).
- **Unit** — the smallest indivisible piece of text chunking will pack: a speaker **turn** in a
  transcript, or a sentence in a document. Units are never split across chunks.
- **Embedding / vector** — a list of numbers a model produces to represent the *meaning* of a piece
  of text, positioned in a high-dimensional space so that texts with similar meaning land near each
  other. It is the bridge from language to math: once text is an embedding, "find related text"
  becomes the geometric problem "find nearby vectors" (measured with cosine similarity — see
  [ADR-0005](0005-retrieval-brute-force-default-index-opt-in.md)). Chunks are embedded so they can be
  searched by meaning, and the quality of a chunk sets a ceiling on the quality of its embedding,
  which is why chunking gets so much care.
- **Partition key** — a column (e.g. `call_id`) that bounds chunking: a chunk never spans two
  partitions, so turns from different calls never end up in the same chunk.
- **Lineage** — the record of which source rows produced an output. Each chunk carries `source_rows`
  so a retrieved chunk can be traced back to (and cite) its origin.
- **Window function** — SQL that computes across a set of rows relative to the current row (e.g. a
  running total with `SUM(...) OVER`). Chunk numbering is done with window functions.
- **Deterministic** — the same input always yields the same output, with no randomness, this is
  why chunking (unlike an AI call) can be asserted exactly in tests.
