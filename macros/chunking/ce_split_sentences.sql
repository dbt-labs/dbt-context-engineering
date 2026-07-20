{#-
  ce_split_sentences — split a document's text into one row per sentence (DECISIONS.md D5, the
  deferred layer-1 splitter, now built). This is the STAGING half of chunking: cheap, deterministic,
  ZERO AI cost. Feed its output to ce_chunk (unit = sentence, partition = document_id) to get the
  full "recursive splitter" pattern: (1) split text -> natural units [here]; (2) pack units into
  token-bounded chunks [ce_chunk].

  Boundary rule: naive sentence-terminator runs ([.!?]). Deterministic and portable, but NAIVE —
  abbreviations ("Inc.", "e.g.") and decimals ("3.5") will over-split. For prose that needs better
  boundaries, split upstream with a real tokenizer and feed those rows to ce_chunk instead.

  Only the extract-all + explode step diverges per engine (extract-all doesn't exist on Snowflake,
  and each engine explodes an array differently), so it is dispatched. The outer wrapper —
  sentence_id (lineage), empty-sentence filter, ordering — is shared. Confirmed live on all four
  engines 2026-07-17.

  Args:
    relation      input model/ref/relation of documents.
    id_column     document id -> carried as document_id and into sentence_id (LINEAGE, required).
    text_column   the full document text to split.

  Returns a SELECT of: sentence_id, document_id, sentence_index (1-based), sentence_text.
-#}

{% macro ce_split_sentences(relation, id_column, text_column) -%}
    with _ce_sentences as (
        {{ adapter.dispatch('ce_split_sentences_core', 'dbt_context_engineering')(relation, id_column, text_column) }}
    )
    select
        cast(document_id as {{ dbt.type_string() }}) || '-' || cast(sentence_index as {{ dbt.type_string() }}) as sentence_id,
        document_id,
        sentence_index,
        sentence_text
    from _ce_sentences
    where sentence_text is not null and trim(sentence_text) <> ''
    order by document_id, sentence_index
{%- endmacro %}


{#- duckdb (also the credential-free default): regexp_extract_all + UNNEST WITH ORDINALITY. -#}
{% macro default__ce_split_sentences_core(relation, id_column, text_column) -%}
    select
        {{ id_column }} as document_id,
        u.sentence_index as sentence_index,
        trim(u.sentence_text) as sentence_text
    from {{ relation }},
         unnest(regexp_extract_all({{ text_column }}, '[^.!?]+[.!?]*')) with ordinality as u(sentence_text, sentence_index)
{%- endmacro %}


{#- BigQuery: REGEXP_EXTRACT_ALL returns an array; UNNEST ... WITH OFFSET gives a 0-based index. -#}
{% macro bigquery__ce_split_sentences_core(relation, id_column, text_column) -%}
    select
        {{ id_column }} as document_id,
        sentence_index + 1 as sentence_index,
        trim(sentence_text) as sentence_text
    from {{ relation }},
         unnest(regexp_extract_all({{ text_column }}, r'[^.!?]+[.!?]*')) as sentence_text with offset as sentence_index
{%- endmacro %}


{#- Databricks/Spark: regexp_extract_all(…, 0) + LATERAL VIEW posexplode (0-based pos). -#}
{% macro databricks__ce_split_sentences_core(relation, id_column, text_column) -%}
    select
        {{ id_column }} as document_id,
        p.sentence_index + 1 as sentence_index,
        trim(p.sentence_text) as sentence_text
    from {{ relation }}
         lateral view posexplode(regexp_extract_all({{ text_column }}, '[^.!?]+[.!?]*', 0)) p as sentence_index, sentence_text
{%- endmacro %}


{#- Snowflake has no regexp_extract_all: insert a sentinel after each terminator+whitespace run,
    SPLIT on it, then LATERAL FLATTEN. The trailing empty element is dropped by the outer filter. -#}
{% macro snowflake__ce_split_sentences_core(relation, id_column, text_column) -%}
    select
        {{ id_column }} as document_id,
        f.index + 1 as sentence_index,
        trim(f.value::string) as sentence_text
    from {{ relation }},
         lateral flatten(input => split(
             regexp_replace({{ text_column }}, '([.!?]+)[[:space:]]', '\\1~~CE_SENT~~'), '~~CE_SENT~~'
         )) f
{%- endmacro %}
