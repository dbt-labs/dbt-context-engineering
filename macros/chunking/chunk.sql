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
    chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate
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
    {%- set assembled = (label_column ~ " || ': ' || " ~ text_column) if label_column is not none else text_column -%}

with _ce_units as (
    select
        {{ id_column }}        as _unit_id,
        {{ order_column }}     as _unit_order,
        {{ partition_select }} as _partition_key,
        {{ assembled }}        as _unit_text,
        ceil(length({{ assembled }}) / 4.0) as _unit_tokens
    from {{ relation }}
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
    from _ce_units
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
    ceil(length(chunk_text) / 4.0) as token_estimate
from _ce_chunks
order by _partition_key, _chunk_seq

{%- endmacro %}
