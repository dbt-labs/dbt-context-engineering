{#-
  chunk — pack ordered, atomic text UNITS into token-bounded chunks (spec §5.3, ADR-0002).

  One operation for both use cases: a "unit" is one input row of text. For transcripts a unit
  is a turn (partition by call_id); for documents a unit is a sentence/paragraph (split upstream,
  partition by document_id). Units are never split; chunks never cross the partition key; every
  unit's id is carried into source_rows for lineage.

  Mechanism (pure window SQL — portable, deterministic, ZERO AI cost):
    tok        = ceil(char_length(assembled_unit_text) / 4)      -- no AI call
    cum_before = running SUM(tok) over the partition, excluding the current row
    chunk_seq  = dense_rank of floor(cum_before / target_tokens) within the partition
  Units are atomic, so the cap is SOFT: a chunk may overshoot target by up to one unit.

  Only the ordered array/string aggregation diverges per engine — isolated in the dispatched
  helpers array_agg / string_agg. The window arithmetic is identical everywhere.

  Args:
    relation          input model/ref/relation of text units
    id_column         stable unit id -> source_rows (LINEAGE, required)
    order_column      orderable key (turn_index / sentence_index / ts) -> deterministic sequence
    text_column       the unit text
    partition_column  chunks never span this (e.g. call_id, document_id). optional.
    label_column      optional prefix per unit in chunk_text (e.g. speaker) -> "label: text"
    target_tokens     soft token cap per chunk. default var('chunk_target_tokens', 512)
    overlap_tokens    sliding overlap in tokens. default var('chunk_overlap_tokens', 0)
    join_separator    how unit texts are concatenated. default newline.

  Returns a SELECT usable as a model body:
    chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate,
    exceeds_target, partition_hash

  exceeds_target   token_estimate > target_tokens. The soft cap is bounded only by the largest
                   single unit, so this flags a chunk that may exceed a downstream embedding
                   endpoint's hard input limit.
  partition_hash   this partition's content fingerprint, always emitted. Materializing as
                   incremental with unique_key='partition_key' and
                   incremental_strategy='delete+insert' turns it into partition-level delta
                   processing: chunk() compares it against the stored value and rebuilds only
                   the partitions whose content changed. Whole-partition replacement is required
                   because a re-chunk can renumber or drop a partition's chunks, so chunk_id is
                   not a stable identity to merge on.
-#}

{% macro chunk(relation, id_column, order_column, text_column,
                  partition_column=none, label_column=none,
                  target_tokens=none, overlap_tokens=none, join_separator='\n') -%}

    {%- if id_column is none or order_column is none or text_column is none -%}
        {{ exceptions.raise_compiler_error(
            "chunk: id_column, order_column, and text_column are all required.") }}
    {%- endif -%}

    {%- set target_tokens = target_tokens if target_tokens is not none else var('chunk_target_tokens', 512) -%}
    {%- set overlap_tokens = overlap_tokens if overlap_tokens is not none else var('chunk_overlap_tokens', 0) -%}

    {%- if target_tokens <= 0 -%}
        {{ exceptions.raise_compiler_error("chunk: target_tokens must be > 0 (got " ~ target_tokens ~ ").") }}
    {%- endif -%}
    {%- if overlap_tokens < 0 -%}
        {{ exceptions.raise_compiler_error("chunk: overlap_tokens must be >= 0 (got " ~ overlap_tokens ~ ").") }}
    {%- endif -%}
    {%- if overlap_tokens >= target_tokens -%}
        {{ exceptions.raise_compiler_error(
            "chunk: overlap_tokens (" ~ overlap_tokens ~ ") must be < target_tokens (" ~ target_tokens ~ ").") }}
    {%- endif -%}
    {#- Overlap uses a 2-chunk model: a unit lands in its own chunk and, if it falls within the
        first `overlap` tokens, also the previous chunk. That holds when overlap < step (i.e.
        2*overlap < target), which covers every sane overlap (best practice is 10-20%).
        Pathological >= 50% overlap is rejected. Pure portable SQL — no per-engine series generator. -#}
    {%- if overlap_tokens > 0 and (2 * overlap_tokens) >= target_tokens -%}
        {{ exceptions.raise_compiler_error(
            "chunk: overlap_tokens (" ~ overlap_tokens ~ ") must be < half of target_tokens ("
            ~ target_tokens ~ "). Overlap >= 50% is not supported (and not advisable).") }}
    {%- endif -%}
    {%- set step = target_tokens - overlap_tokens -%}

    {%- set str_t = dbt.type_string() -%}
    {%- set partition_select = partition_column if partition_column is not none else "cast(null as " ~ str_t ~ ")" -%}
    {#- Coalesce before assembly, not after. A null text (or null label) makes the whole
        `label || ': ' || text` concat null on every engine, and an ordered string agg then drops
        that unit from chunk_text entirely, not even leaving a separator, while source_rows and
        n_source_rows still count it. That is a lineage claim the text cannot support (ADR-0011),
        and with a label it silently loses the speaker attribution too. Coalescing keeps the unit
        present as an empty (or label-only) contribution, so the gap is visible and source_rows
        stays honest. -#}
    {%- set safe_text = "coalesce(" ~ text_column ~ ", '')" -%}
    {%- set safe_label = "coalesce(" ~ label_column ~ ", '')" if label_column is not none else none -%}
    {%- set assembled = (safe_label ~ " || ': ' || " ~ safe_text) if label_column is not none else safe_text -%}

    {%- set chunk_fp = dbt_context_engineering.chunk_fn_fingerprint(
        target_tokens=target_tokens, overlap_tokens=overlap_tokens,
        join_separator=join_separator, id_column=id_column, order_column=order_column,
        text_column=text_column, partition_column=partition_column,
        label_column=label_column) -%}

with _ce_units as (
    select
        {{ id_column }}        as _unit_id,
        {{ order_column }}     as _unit_order,
        {{ partition_select }} as _partition_key,
        {{ assembled }}        as _unit_text,
        ceil(length({{ assembled }}) / 4.0) as _unit_tokens
    from {{ relation }}
),

{#- One hash per _partition_key, over every unit's id + text in order, so an insert, delete,
    edit, or reorder anywhere in the partition changes it. _unit_text is already non-null by
    construction above; _unit_id is coalesced because a null id would otherwise null the whole
    concat and make that unit invisible to the delta check, silently freezing its partition.
    The call fingerprint is folded in as a prefix so a pure config change (a different
    target_tokens, a different text_column) invalidates every partition even though not one
    input byte moved. See chunk_fn_fingerprint() for why that is not redundant with the
    content hash. It is a hex literal, so it needs no escaping here.
    Computed over the FULL _ce_units (every partition, not just dirty ones), since that is the
    only way to know which partitions are dirty. Cheap: one pass, zero AI cost, no window
    functions, and it is what lets the expensive work below be skipped. -#}
_ce_partition_hash as (
    select
        _partition_key,
        {{ dbt_context_engineering.content_hash(
            "'" ~ chunk_fp ~ "::' || " ~ adapter.dispatch('string_agg', 'dbt_context_engineering')(
                "coalesce(cast(_unit_id as " ~ str_t ~ "), '') || ':' || _unit_text", '|', '_unit_order')
        ) }} as _partition_hash
    from _ce_units
    group by _partition_key
),

{#- Macro-owned cache key, not caller-assembled: chunk() computes and compares its own hash
    formula, so there's exactly one place it can drift out of sync with itself. Only meaningful
    with a real partition_column (a single implicit partition has nothing smaller to skip), and
    only once `this` exists with a partition_hash column to compare against (guaranteed from the
    first build onward, since chunk() always emits partition_hash). On first build /
    --full-refresh, every partition is "dirty" by omitting the filter entirely. -#}
_ce_dirty_partitions as (
    select _partition_key
    from _ce_partition_hash
    {%- if partition_column is not none and is_incremental() %}
    where {{ dbt_context_engineering.row_value_not_in(
        ['_partition_key', '_partition_hash'],
        "(select partition_key as _partition_key, partition_hash as _partition_hash from " ~ this ~ ")"
    ) }}
    {%- endif %}
),

{#- Everything from here down only ever sees dirty partitions' units. Paired with
    config(incremental_strategy='delete+insert', unique_key='partition_key') at the model level,
    a dirty partition's old chunk rows are fully replaced (never merged by chunk_id, which isn't
    a stable identity across a re-chunk), and an untouched partition is never re-scanned past
    the hash check above, never rewritten, and never surfaces as changed to a downstream
    content_hash check. -#}
_ce_units_scoped as (
    select u.*
    from _ce_units u
    {%- if partition_column is not none and is_incremental() %}
    where u._partition_key in (select _partition_key from _ce_dirty_partitions)
    {%- endif %}
),

_ce_binned as (
    select
        _unit_id, _unit_order, _partition_key, _unit_text,
        coalesce(
            sum(_unit_tokens) over (
                partition by _partition_key
                order by _unit_order
                rows between unbounded preceding and 1 preceding
            ), 0
        ) as _cum_before
    from _ce_units_scoped
),

_ce_primary as (
    select
        _unit_id, _unit_order, _partition_key, _unit_text, _cum_before,
        cast(floor(_cum_before / {{ step }}) as {{ dbt.type_bigint() }}) as _primary_k
    from _ce_binned
),

_ce_exploded as (
    -- every unit belongs to its own chunk ...
    select _unit_id, _unit_order, _partition_key, _unit_text, _primary_k as _raw_k
    from _ce_primary
    {%- if overlap_tokens > 0 %}
    union all
    -- ... and to the previous chunk when it lands within the first `overlap` tokens of its own.
    select _unit_id, _unit_order, _partition_key, _unit_text, _primary_k - 1 as _raw_k
    from _ce_primary
    where _primary_k > 0
      and (_cum_before - _primary_k * {{ step }}) < {{ overlap_tokens }}
    {%- endif %}
),

_ce_assigned as (
    select
        _unit_id, _unit_order, _partition_key, _unit_text,
        dense_rank() over (partition by _partition_key order by _raw_k) as _chunk_seq
    from _ce_exploded
),

_ce_chunks as (
    select
        _partition_key,
        _chunk_seq,
        {{ adapter.dispatch('array_agg', 'dbt_context_engineering')('_unit_id', '_unit_order') }}                    as source_rows,
        {{ adapter.dispatch('string_agg', 'dbt_context_engineering')('_unit_text', join_separator, '_unit_order') }} as chunk_text,
        count(*)                                                             as n_source_rows
    from _ce_assigned
    group by _partition_key, _chunk_seq
),

_ce_sized as (
    select
        c._partition_key,
        c._chunk_seq,
        c.source_rows,
        c.chunk_text,
        c.n_source_rows,
        ceil(length(c.chunk_text) / 4.0) as token_estimate,
        h._partition_hash
    from _ce_chunks c
    left join _ce_partition_hash h
        on c._partition_key = h._partition_key
        or (c._partition_key is null and h._partition_key is null)
)

select
    {% if partition_column is not none -%}
    cast(_partition_key as {{ str_t }}) || '::' || cast(_chunk_seq as {{ str_t }})
    {%- else -%}
    cast(_chunk_seq as {{ str_t }})
    {%- endif %} as chunk_id,
    _partition_key as partition_key,
    _chunk_seq     as chunk_seq,
    source_rows,
    chunk_text,
    n_source_rows,
    token_estimate,
    {#- The cap is soft (ADR-0002): a unit is never split, so the unit that crosses a boundary
        lands in the current chunk and can push it past target_tokens. Usually that is a small
        overshoot, but it is bounded only by the largest single unit, so one oversized unit
        yields an oversized chunk that no packing strategy could have prevented. Downstream that
        matters: embedding endpoints have hard input limits (e.g. snowflake-arctic-embed-m-v1.5
        at 512 tokens) and truncate or error well after chunking, where the cause is not obvious.
        Emitted as a column rather than a raised error because unit sizes are only known at run
        time, and it is a data-quality signal to filter or alert on, not a config mistake. -#}
    token_estimate > {{ target_tokens }} as exceeds_target,
    _partition_hash as partition_hash
from _ce_sized
order by _partition_key, _chunk_seq

{%- endmacro %}
