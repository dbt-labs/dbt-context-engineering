{#-
  ce_attach_metadata — join source-level metadata (frontmatter, provenance, or any column
  constant per partition) onto the output of ce_chunk, keyed on partition_key.

  Deliberately separate from ce_chunk. Carrying a value that is constant per partition onto every
  chunk row is a group-by max() plus a join — plain ANSI SQL, no per-engine divergence to hide —
  so it does not belong inside a dispatched macro. Composing it as a step after ce_chunk keeps
  ce_chunk's own internals (the one place with real per-engine risk: ordered array/string
  aggregation) untouched by an unrelated concern, and lets any relation with a source-level grain
  feed it directly — chunking does not need to know metadata exists, and a splitter step
  (ce_split_sentences) does not need to carry it through the split either.

  metadata_columns is caller-defined and semantically agnostic: pass frontmatter fields
  (customer, participants, assignee), provenance fields (citation_url, recording_url), or any
  other source-level columns. The macro does not distinguish between them.

  Args:
    chunks_relation       output of ce_chunk (or anything with the same shape: chunk_id,
                           partition_key, chunk_seq, source_rows, chunk_text, n_source_rows,
                           token_estimate)
    metadata_relation     a relation with one row per partition key — typically the source-level
                           table, upstream of any split/chunk step — carrying metadata_columns
    metadata_key_column   the column in metadata_relation that matches chunks_relation's
                           partition_key (e.g. document_id, call_id)
    metadata_columns      non-empty list of column names to carry onto every chunk row.
                           Picked via max(), so a column's value must actually be constant per
                           key — if it varies, only the max value survives silently.
    in_text               if True, also prepend a "col: value" block (one line per
                           metadata_columns entry, terminated with a "---" line) to chunk_text,
                           so the embedding/LLM sees it on every chunk, and recompute
                           token_estimate to reflect the added text. Default False — metadata
                           stays in passthrough columns only (no duplication into the embedded
                           text, no token cost).

  Returns a SELECT usable as a model body: every ce_chunk output column, plus metadata_columns.
-#}

{% macro ce_attach_metadata(chunks_relation, metadata_relation, metadata_key_column,
                             metadata_columns, in_text=false) -%}

    {%- if metadata_columns is none or (metadata_columns | length) == 0 -%}
        {{ exceptions.raise_compiler_error(
            "ce_attach_metadata: metadata_columns must be a non-empty list.") }}
    {%- endif -%}

    {%- set str_t = dbt.type_string() -%}

    {%- set md_lines = [] -%}
    {%- for mc in metadata_columns -%}
        {%- do md_lines.append(
            "'" ~ mc ~ ": ' || coalesce(cast(meta." ~ mc ~ " as " ~ str_t ~ "), '') || chr(10)"
        ) -%}
    {%- endfor -%}
    {%- set md_prefix_expr = (md_lines | join(' || ')) ~ " || '---' || chr(10)" -%}

with _ce_metadata as (
    select
        {{ metadata_key_column }} as _meta_key
        {%- for mc in metadata_columns %}
        , max({{ mc }}) as {{ mc }}
        {%- endfor %}
    from {{ metadata_relation }}
    group by {{ metadata_key_column }}
),

{#- chunk_text computed once here, in a genuine subquery column, not a same-SELECT alias:
    BigQuery does not resolve a SELECT-list alias referenced later in that same SELECT (the same
    trap ce_chunk itself hit — see its _ce_final CTE). -#}
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
