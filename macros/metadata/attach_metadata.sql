{#-
  attach_metadata — join source-level metadata (frontmatter, provenance, or any column
  constant per partition) onto the output of chunk, keyed on partition_key.

  Deliberately separate from chunk. Carrying a value that is constant per partition onto every
  chunk row is a distinct collapse plus a join, plain ANSI SQL with no per-engine divergence to
  hide, so it does not belong inside a dispatched macro. Composing it as a step after chunk keeps
  chunk's own internals (the one place with real per-engine risk: ordered array/string
  aggregation) untouched by an unrelated concern, and lets any relation with a source-level grain
  feed it directly — chunking does not need to know metadata exists, and a splitter step
  (split_sentences) does not need to carry it through the split either.

  metadata_columns is caller-defined and semantically agnostic: pass frontmatter fields
  (customer, participants, assignee), provenance fields (citation_url, recording_url), or any
  other source-level columns. The macro does not distinguish between them. This flatness is
  deliberate and is the transform layer's stance: metadata is just columns to carry. It is the
  opposite of knowledge_base, which promotes citation_url to a first-class column on purpose,
  because the knowledge base is a serving contract and a resolvable citation is part of that
  contract. Generic transform, flat metadata; serving contract, privileged provenance.

  Args:
    chunks_relation       output of chunk (or anything with the same shape: chunk_id,
                           partition_key, chunk_seq, source_rows, chunk_text, n_source_rows,
                           token_estimate)
    metadata_relation     a relation with one row per partition key — typically the source-level
                           table, upstream of any split/chunk step — carrying metadata_columns
    metadata_key_column   the column in metadata_relation that matches chunks_relation's
                           partition_key (e.g. document_id, call_id)
    metadata_columns      non-empty list of column names to carry onto every chunk row.
                           metadata_relation is collapsed to one row per key via SELECT DISTINCT,
                           so each column must be functionally dependent on metadata_key_column
                           (constant per key). If a key carries conflicting values, DISTINCT
                           yields more than one row for it, the join fans out the chunks, and the
                           chunk_id uniqueness test fails loudly. That is by design: a broken
                           dependency surfaces as a failed test, not as a silently chosen value.
                           Enforcement lives on tiers that test chunk_id uniqueness (all four
                           integration projects).
    in_text               if True, also prepend a "col: value" block (one line per
                           metadata_columns entry, terminated with a "---" line) to chunk_text,
                           so the embedding/LLM sees it on every chunk, and recompute
                           token_estimate to reflect the added text. Default False — metadata
                           stays in passthrough columns only (no duplication into the embedded
                           text, no token cost).

  Returns a SELECT usable as a model body: every chunk output column, plus metadata_columns.
-#}

{% macro attach_metadata(chunks_relation, metadata_relation, metadata_key_column,
                             metadata_columns, in_text=false) -%}

    {%- if metadata_columns is none or (metadata_columns | length) == 0 -%}
        {{ exceptions.raise_compiler_error(
            "attach_metadata: metadata_columns must be a non-empty list.") }}
    {%- endif -%}

    {%- set str_t = dbt.type_string() -%}

    {%- set md_lines = [] -%}
    {%- for mc in metadata_columns -%}
        {%- do md_lines.append(
            "'" ~ mc ~ ": ' || coalesce(cast(meta." ~ mc ~ " as " ~ str_t ~ "), '') || chr(10)"
        ) -%}
    {%- endfor -%}
    {%- set md_prefix_expr = (md_lines | join(' || ')) ~ " || '---' || chr(10)" -%}

{#- Collapse metadata_relation to one row per key with DISTINCT, not an aggregate. When each
    column is functionally dependent on the key (the contract), the rows are identical and DISTINCT
    yields exactly one per key. When a key carries conflicting values, DISTINCT yields several
    rows, the join below fans out the chunks, and chunk_id uniqueness fails — a loud, testable
    failure instead of an aggregate silently picking one value. -#}
with _ce_metadata as (
    select distinct
        {{ metadata_key_column }} as _meta_key
        {%- for mc in metadata_columns %}
        , {{ mc }}
        {%- endfor %}
    from {{ metadata_relation }}
),

{#- chunk_text computed once here, in a genuine subquery column, not a same-SELECT alias:
    BigQuery does not resolve a SELECT-list alias referenced later in that same SELECT (the same
    trap chunk itself hit — see its _ce_final CTE). -#}
_ce_joined as (
    select
        c.chunk_id,
        c.partition_key,
        c.chunk_seq,
        c.source_rows,
        c.n_source_rows,
        {% if in_text -%}
        ({{ md_prefix_expr }} || c.chunk_text) as chunk_text
        {%- else -%}
        c.chunk_text as chunk_text
        {%- endif %}
        {%- for mc in metadata_columns %}
        , meta.{{ mc }}
        {%- endfor %}
    from {{ chunks_relation }} c
    left join _ce_metadata meta
        on cast(c.partition_key as {{ str_t }}) = cast(meta._meta_key as {{ str_t }})
)

select
    chunk_id,
    partition_key,
    chunk_seq,
    source_rows,
    chunk_text,
    n_source_rows,
    ceil(length(chunk_text) / 4.0) as token_estimate
    {%- for mc in metadata_columns %}
    , {{ mc }}
    {%- endfor %}
from _ce_joined
order by partition_key, chunk_seq

{%- endmacro %}
