{#-
  ce_knowledge_base(sources) — compose multiple pre-embedded source tables (tickets, calls, notes,
  emails, …) into one queryable mart with a common shape, so a single ce_vector_search answers
  "everything about account X" across systems (spec §7, Phase 6).

  Each source is normalized to: source_type, source_id, account_key, text, embedding, ts. Per-source
  lineage (source_type + source_id) is preserved into every row, so a retrieval result can cite
  which system and row it came from. The union is pure SQL and portable; the embeddings themselves
  come from ce_embed upstream (each source must already carry an embedding column produced by the
  SAME embedding model — see ce_version_guard).

  `sources` is a list of dicts; register a new source by adding one entry:
    {{ ce_knowledge_base([
        {'relation': ref('stg_tickets'), 'source_type': 'ticket',
         'source_id': 'ticket_id', 'account_key': 'account_id',
         'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at'},
        {'relation': ref('stg_calls'), 'source_type': 'call',
         'source_id': 'call_id', 'account_key': 'account_id',
         'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time'},
    ]) }}

  Returns a SELECT (union across sources). Use as a model body; then search it with
  ce_vector_search(..., filter="account_key = '<acct>'").
-#}
{% macro ce_knowledge_base(sources) -%}
    {%- if sources is none or (sources | length) == 0 -%}
        {{ exceptions.raise_compiler_error("ce_knowledge_base: `sources` must be a non-empty list of source dicts.") }}
    {%- endif -%}
    {%- set required = ['relation', 'source_type', 'source_id', 'account_key', 'text', 'embedding', 'timestamp'] -%}
    {%- set str_t = dbt.type_string() -%}
    {%- for s in sources -%}
        {%- for k in required -%}
            {%- if k not in s -%}
                {{ exceptions.raise_compiler_error("ce_knowledge_base: source #" ~ loop.index ~ " is missing key '" ~ k ~ "'.") }}
            {%- endif -%}
        {%- endfor -%}
select
    {{ "'" ~ s.source_type ~ "'" }} as source_type,
    cast({{ s.source_id }} as {{ str_t }})    as source_id,
    cast({{ s.account_key }} as {{ str_t }})  as account_key,
    {{ s.text }}      as text,
    {{ s.embedding }} as embedding,
    {{ s.timestamp }} as ts
from {{ s.relation }}
{% if not loop.last %}union all
{% endif %}
    {%- endfor -%}
{%- endmacro %}
