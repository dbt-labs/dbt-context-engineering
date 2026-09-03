# 29. chunk: partition-level incremental refresh and data-shape guarantees

## Status

Accepted, 2026-09-02.

Supersedes the worked example in [ADR-0002](0002-chunking-as-token-bounded-unit-packing.md), which
depicts a packing algorithm the implementation has never had. ADR-0002's founding principles stay
in force: units are never split, chunks never cross a partition, and lineage is carried on every
chunk.

## Concept

A **chunk** is a bounded piece of text small enough to embed and retrieve. `chunk()` builds them by
packing whole **units** (a sentence, a speaker turn) into a token budget, never splitting one.

Two questions follow from that, and this record answers both.

The first is what the packing actually produces at the awkward edges. What happens to a unit larger
than the entire budget? To a unit whose text is `NULL`? To a partition where every unit is `NULL`?
These are not exotic. Real corpora contain empty transcript turns and oversized pasted blocks.

The second is how to avoid re-chunking a corpus that mostly did not change. The obvious instinct is
a row-level delta, the same shape used elsewhere in this package. That instinct is wrong here, and
the reason is worth holding onto: **a chunk's identity depends on every unit ordered before it in
its partition.** Chunk assignment is driven by a running token total taken from the start of the
partition. Insert one unit in the middle and every later chunk boundary can move. There is no
smaller safe unit of work than the whole partition.

## Context

`chunk()` assigns each unit to a chunk with a prefix sum over the partition:

```sql
_cum_before = SUM(_unit_tokens) OVER (
    PARTITION BY _partition_key ORDER BY _unit_order
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
_primary_k  = floor(_cum_before / step)
```

Three facts fall out of that shape.

**Chunk boundaries cascade within a partition, and only within it.** Every window function is
partitioned by `_partition_key` and no aggregate crosses partitions. So an edit anywhere in a
partition can move every later boundary in that partition, and can never affect another one.

**`chunk_id` is not a durable identity.** It is `{partition_key}::{chunk_seq}`, and `chunk_seq` is
a dense rank. Remove a unit and a partition that produced four chunks may now produce three. The
fourth `chunk_id` simply stops being produced.

**The package's existing delta primitives are row-level.** `incremental_delta_predicate` and
`content_hash` (see [ADR-0023](0023-embedding-metadata-and-content-hash-delta.md)) compare a row's
key and a hash of its text. Neither can express "this partition changed, rebuild all of it."

Separately, ADR-0002 documents a worked example that the code does not produce. For units of
18, 17, 25, 12 and 30 tokens at a budget of 40, that diagram shows three chunks of 35, 37 and 30,
none over budget, formed by closing a chunk before admitting the unit that would exceed it. That
is greedy first-fit with lookahead. The implementation has no lookahead. A running sum that resets
on a threshold cannot be written with ordinary window functions, only with a recursive CTE, which
would break the portability and near-zero cost that ADR-0002 itself treats as load-bearing.

## Decision

**We will make the partition the unit of incremental work, and have `chunk()` own the cache key that
decides which partitions are dirty.** `chunk()` emits `partition_hash` on every build. When the
model is incremental, `chunk()` compares that hash against the stored value itself and restricts all
downstream work to partitions whose content or configuration changed. The caller supplies only the
materialization.

```sql
{{ config(materialized='incremental', unique_key='partition_key',
          incremental_strategy='delete+insert') }}
{{ dbt_context_engineering.chunk(
    relation=ref('units'), id_column='unit_id', order_column='turn_index',
    text_column='unit_text', partition_column='document_id', target_tokens=512) }}
```

Four specific commitments:

**1. `partition_hash` is always emitted, and folds in a call fingerprint.** The hash covers each
unit's id and text in order, prefixed by `chunk_fn_fingerprint()`, a compile-time `local_md5` over
every argument that changes output. Without that prefix a pure config change is undetectable,
because the input rows are untouched.

**2. Replacement is whole-partition, keyed on `partition_key`.** Never a merge on `chunk_id`. A
partition that sheds a chunk must have that chunk deleted, not left behind.

**3. Null text is coalesced before assembly.** `coalesce(text, '')` and `coalesce(label, '')` run
before `label || ': ' || text` is built.

**4. `exceeds_target` is emitted as a boolean, not raised as an error.** It is
`token_estimate > target_tokens`.

Supported materializations:

| materialization | duckdb | Snowflake | Databricks | BigQuery |
|---|---|---|---|---|
| `table` / `view` | yes | yes | yes | yes |
| `incremental` | `delete+insert` | `delete+insert` | `insert_overwrite` + `partition_by` | not supported |

## Reasoning

**Why the partition, and not the row.** A row-level delta would have to predict which chunks an
edit disturbs. Because assignment is a prefix sum, the honest answer is "possibly all of them after
the edit point." Partition-level rebuild sidesteps the question rather than approximating it. It
also subsumes the easy case of a brand new partition, which needs no separate code path.

**Why `chunk()` owns the hash instead of the caller passing a filter.** A caller-supplied cache key
makes the caller responsible for restating the macro's own inputs. The two then drift silently,
because a missed input is a coverage gap rather than a compiler error. Here the formula lives in
exactly one place, so it cannot disagree with itself.

**Why the fingerprint is folded into `partition_hash` rather than gated by `version_guard`.**
`version_guard` is the established idiom for forcing a full reprocess
([ADR-0004](0004-version-aware-incremental-refresh.md)). Folding the fingerprint into the hash
achieves the same result with one mechanism instead of two and no additional metadata query per
build. Rows written before the hash existed carry no comparable value, so nothing matches and every
partition is correctly treated as dirty on first adoption.

The cost of that is real and worth stating plainly. Because the fingerprint is package-controlled,
changing the key set in `chunk_fn_fingerprint` or the hash composition in `chunk()` invalidates
every stored `partition_hash` and forces a full corpus rebuild. Ordinary package upgrades do not
trigger this, only changes to those two specific things. When it does happen the blast radius is
warehouse compute alone: `chunk_text` and `chunk_id` are unchanged, so a downstream `embed()`
content-hash delta sees nothing and no AI spend follows. `chunk_fn_fingerprint` therefore carries an
`extra` placeholder, mirroring `embedding_fn_fingerprint`'s `dimension`, so a future argument can be
routed through it without disturbing the key set.

**Why a null unit is coalesced rather than dropped or rejected.** With `text` null, the whole
assembled expression is null on every engine, and an ordered string aggregate then drops that unit
from `chunk_text` without even leaving a separator. Meanwhile `source_rows` and `n_source_rows`
still count it. The chunk then claims lineage its text cannot support, which
[ADR-0011](0011-lineage-and-citations-as-a-first-class-invariant.md) forbids. With a label the loss
is worse, because the speaker attribution disappears too. Dropping the unit outright would keep
lineage honest but silently discard a row. Rejecting at parse time is impossible, since unit
content is only known at run time.

This is also load-bearing for the delta mechanism, not only for citations. Without the coalesce, a
partition whose units are all null produces a null `chunk_text`, and therefore a null
`partition_hash`, so that partition drops out of change detection entirely.

**Why `exceeds_target` is a flag and not an error.** Units are atomic, so a unit larger than the
budget always yields an oversized chunk. No packing strategy avoids it. Greedy first-fit would
isolate the oversized unit rather than pairing it with a neighbour, but the chunk is oversized
either way. It matters downstream because embedding endpoints have hard input limits and truncate
or fail well after chunking, where the cause is not obvious. Unit sizes are only known at run time,
so this is a data-quality signal to filter or alert on.

**Why BigQuery gets no incremental path.** BigQuery offers `merge`, `insert_overwrite` and
`microbatch`. Each fails for this shape, and the first fails silently, which is the worst outcome.
`chunk()` is deterministic and costs no AI spend, so a full rebuild on BigQuery costs warehouse
compute only. A downstream `embed()` still skips re-embedding, because `chunk_text` is
byte-identical for unchanged partitions.

## Evidence

All figures below are the observed output of the committed fixtures, identical on duckdb,
Snowflake, Databricks and BigQuery unless stated.

**ADR-0002's worked example, as actually produced.** Fixture `chunk_edge_units`, partition
`adr_ex`, units of 18, 17, 25, 12 and 30 tokens at `target_tokens=40`:

```
partition  seq  n_rows  token_estimate  exceeds_target  source_rows
adr_ex     1    3       61              true            e1,e2,e3
adr_ex     2    2       43              true            e4,e5
```

Two chunks, both over budget. ADR-0002's diagram shows three chunks of 35, 37 and 30, none over
budget.

**Overshoot is bounded by the largest unit, not by one small unit.** Partition `oversize`, a
400-token unit at a 40-token budget:

```
oversize   1    2       405             true            o1,o2
oversize   2    1       4               false           o3
```

**Null text keeps its lineage and its label.** Partition `null_mid` is three units with the middle
one null. Unlabeled, `chunk_text` is 82 characters: 40, a separator, the empty unit, a separator,
40. Without the coalesce it is 81, because the null unit leaves no separator at all. Labeled, it is
91 characters, the extra 3 being the `"S: "` that survives for the null unit. Without the coalesce
it is 87. An all-null partition yields length 1, the separator between two empty units, rather than
a null `chunk_text`.

Removing the coalesce fails 6 tests: `assert_chunk_edges`, `assert_chunk_null_lineage`, and three
`not_null` schema tests, one of which is `not_null` on `partition_hash`. The guarantee is therefore
enforced, not merely documented.

**Partition-level delta.** Fixture `chunk_delta_units`, phase 1 then phase 2, at a 20-token budget.
Phase 2 grows one partition, shrinks another so a chunk is vacated, adds a third, and leaves a
fourth untouched:

```
partition  source_rows  built_at
clean      c1,c2        00:33:19   <- phase 1 timestamp, skipped
grow       g1,g2,g3     00:33:34
new        n1,n2        00:33:34
shrink     s1,s2        00:33:34   <- vacated chunk deleted, not left behind
```

`clean` retains its phase-1 `built_at`, proving it was skipped rather than rewritten with identical
content. Snowflake reports `SUCCESS 0` for a no-op run and `SUCCESS 1` when one partition changes.

**Content-only edits are detected.** Replacing one unit's text with a same-length string changes
only that partition. Token counts are identical across the edit, so nothing but the hash could
detect it. All four engines produce `3e3fed10` / `a6233eea` for the edited partition and leave the
other three byte-identical.

**Configuration-only changes are detected.** Lowering `target_tokens` from 20 to 6 rebuilds 4 rows
into 9 on every engine, with Snowflake reporting `SUCCESS 9`. Drop the fingerprint prefix from
`partition_hash` and the same change rebuilds nothing while reporting success, because every input
row is byte-identical and no partition looks dirty. That is what the prefix exists to prevent.

**Cross-engine hash parity.** Four hash implementations (`sha256`, `sha2(x,256)`,
`to_hex(sha256(x))`) and four ordered-aggregation paths produce identical digests for identical
input. Both `text_fp` and `partition_hash` match exactly across all four tiers.

**BigQuery's `merge` corrupts silently.** With `merge` on `partition_key`, phase 2's `shrink`
produced a duplicate:

```
shrink  1  2  s1,s2  9b1aec5d  350fcd1f
shrink  1  2  s1,s2  9b1aec5d  350fcd1f
```

Both stored rows matched the single incoming row and both were updated, so the vacated chunk was
never deleted. dbt reported success with exit code 0. `insert_overwrite` with a `STRING` partition
key is accepted at parse time, silently produces an unpartitioned table, then fails at run time
with `Function not found: string_trunc`. `delete+insert` is rejected outright:
`Expected one of: 'merge', 'insert_overwrite', 'microbatch'`.

## Consequences

- **A partition deleted from source keeps its chunks until a full refresh.** It produces no rows,
  so no strategy keyed on incoming partitions deletes it. Reproduced on Snowflake and Databricks;
  BigQuery is unaffected only because it materializes as a table. `attach_metadata()` and
  `knowledge_base()` have the identical gap on their own keys. An active, DELETE-based sweep was
  considered and rejected: it cannot distinguish a genuine upstream deletion from a source relation
  that came back empty due to a transient failure, and the latter would silently delete real rows,
  a worse outcome than the staleness it would fix. Surfaced instead with a `relationships` test
  between each model and its current upstream output (`orphan_chunks`/`orphan_embeddings`,
  extended to `orphan_amd` and `orphan_kb`/`orphan_kb_valid_keys`; see TESTING.md 4.4), matching
  the shape this package already chose for `chunk_id` orphaning before this ADR.
- **BigQuery consumers lose compute savings, not correctness.** They pay a full rebuild per run.
  AI spend downstream is unaffected, because determinism keeps `chunk_text` stable.
- **The caller must not merge on `chunk_id`.** Whole-partition replacement is mandatory. Enforced:
  `chunk()` itself checks its own caller's `config.get('unique_key')`/`incremental_strategy`/
  `partition_by` when `materialized='incremental'` (the same dispatch-layer pattern
  `require_safe_materialization`/`require_full_refresh_gate` use, not a separate opt-in helper,
  which would only protect a caller who remembers to use it). Also blocks
  `materialized='incremental'` outright on BigQuery, rather than letting a consumer discover the
  Evidence section's `merge`/`insert_overwrite` failures live. Confirmed live: a wrong
  `unique_key`, a wrong `incremental_strategy`, a missing Databricks `partition_by`, and a BigQuery
  incremental attempt are each individually blocked with a message naming the fix, and an
  unrelated, unselected model is unaffected by a bad config existing elsewhere in the project.
- **A chunking config change forces a full corpus rebuild.** Correct, and the alternative is
  serving output built under a configuration that no longer applies.
- **A package-side change to the fingerprint key set or the hash composition also forces a full
  corpus rebuild**, because `partition_hash` is package-controlled. Ordinary upgrades do not trigger
  this. When it happens the cost is warehouse compute only: `chunk_text` and `chunk_id` are
  unchanged, so downstream content-hash deltas see nothing and no AI spend follows. New `chunk()`
  arguments should route through `chunk_fn_fingerprint`'s `extra` placeholder to avoid disturbing
  the key set. Confirmed, not just reasoned: `chunk_fp_probe_chunks`/`chunk_fp_probe_embed`
  (TESTING.md 4.9) swap `id_column` to a column holding identical values under a different name,
  bumping the fingerprint alone. `partition_hash` changed and both partitions were genuinely
  whole-partition rebuilt, `chunk_id`/`chunk_text` stayed byte-identical, and the downstream
  content-hash delta logged `row_count=0`, with `embedded_at` frozen at its prior value confirming
  no re-embedding actually happened, not just an artifact of the row-count measurement.
- **`chunk()` emits two new columns**, `exceeds_target` and `partition_hash`. Confirmed harmless:
  no consumer of `chunk()`'s output (`chunk_docs`, `orphan_chunks`, `attach_metadata`'s
  `chunks_relation` argument, `attach_metadata_delta`'s two-phase test) selects by position or with
  `select *`, and the full regression suite stayed green across every rebuild in this effort.
- **The two-phase delta test is order-dependent.** Phase 1 requires `--full-refresh`. Documented in
  TESTING.md §4.5, matching the existing `ch_edit_id` and `ld_phase` patterns.
- **`exceeds_target` is surfaced as a shipped generic test, `no_oversized_chunks`, opt-in.**
  `columns: [{name: exceeds_target, tests: [dbt_context_engineering.no_oversized_chunks]}]` fails
  the build if any row is oversized, rather than leaving it a column a consumer must remember to
  check. Not the default: `exceeds_target` is a signal about the source corpus, not a package
  correctness bug, the same opt-in treatment `grounded` (Phase 7) already gets. Deliberately a
  shipped test rather than a documented `dbt_utils.expression_is_true` recipe: this package has no
  `dbt_utils` dependency anywhere else. Confirmed live as a genuine negative control: attached
  temporarily to `chunk_edges` (which deliberately contains 3 oversized rows by construction),
  correctly failed naming exactly those 3 rows, then reverted, since `chunk_edges` itself asserts
  the oversized case exists, not that it doesn't.

## Alternatives considered

- **Row-level delta on `chunk_id`.** Rejected. Chunk assignment is a prefix sum, so an edit can move
  every later boundary in the partition, and `chunk_id` is not stable across a re-chunk.
- **Greedy first-fit packing, matching ADR-0002's diagram.** Rejected. It needs a running sum that
  resets on a threshold, which requires a recursive CTE. That breaks the portable window-only SQL
  and near-zero cost ADR-0002 treats as load-bearing.
- **A caller-supplied cache key, passed to `chunk()` as a filter argument.** Rejected. The caller
  would have to restate the macro's own inputs, and an input omitted from that restatement is a
  silent coverage gap rather than a compiler error.
- **A separate `chunk_fingerprint` column gated by `version_guard`.** Rejected in favour of folding
  the fingerprint into `partition_hash`. One mechanism instead of two, and no extra metadata query.
  Two costs: the table no longer shows why a partition is dirty, and a package-side change to the
  fingerprint key set forces a full corpus rebuild.
- **Union unchanged partitions from `this` so output is always the full corpus.** Rejected. It would
  let every engine use one full-replace strategy, but it makes any future column addition a
  breaking change, never revalidates carried-forward rows, and pays a full rewrite on all four
  engines to accommodate one.
- **INT64 bucket partitioning on BigQuery.** Rejected. Bucket collisions mean overwriting a bucket
  deletes clean partitions sharing it, so the dirty set would have to expand to whole buckets. Data
  loss if that expansion is ever wrong.
- **Raising a compiler error for an oversized unit.** Rejected. Unit sizes are only known at run
  time.

## Glossary

- **Unit**: the smallest indivisible piece of text `chunk()` packs, one input row. Never split.
- **Partition**: the boundary a chunk never crosses, set by `partition_column`. Chunk assignment
  depends only on units within the same partition.
- **Prefix sum**: a running total from the start of the partition. Because each unit's chunk depends
  on the total before it, an edit can cascade to every later chunk in that partition.
- **`partition_hash`**: a per-partition fingerprint over every unit's id and text in order, prefixed
  by the call fingerprint. The cache key deciding whether a partition is rebuilt.
- **`chunk_fn_fingerprint`**: a compile-time hash of every `chunk()` argument that changes output.
  Makes a configuration change visible to a hash otherwise taken only over input rows.
- **Dirty partition**: one whose stored `partition_hash` does not match the freshly computed value.
- **Soft cap**: `target_tokens` is a target, not a limit. Because units are atomic, a chunk may
  exceed it by as much as the largest single unit.
- **`exceeds_target`**: boolean, true when a chunk's `token_estimate` exceeds `target_tokens`.
- **Whole-partition replacement**: deleting every stored row for a dirty partition and reinserting.
  Required because a re-chunk can renumber or drop chunks, making `chunk_id` unusable as a merge key.
- **Orphan**: a stored row whose key the source no longer produces. Here, either a chunk vacated by
  a shrinking partition, or every chunk of a partition deleted from source.
