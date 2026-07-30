{#-
  ce_knowledge_base(sources) — compose multiple pre-embedded source tables (tickets, calls, notes,
  emails, …) into one queryable mart with a common shape, so a single ce_vector_search answers
  "everything about account X" across systems (spec §7, Phase 6).

  Each source is normalized to: source_type, source_id, account_key, text, embedding, ts,
  citation_url. Per-source lineage (source_type + source_id) is preserved into every row, so a
  retrieval result can cite which system and row it came from; citation_url (optional per source)
  is a single resolvable link back to that source object (a Notion page, a Salesforce record, a
  ticket URL) — the mechanism for an AI consumer to cite its source, not just identify it. The
  union is pure SQL and portable; the embeddings themselves come from ce_embed upstream (each
  source must already carry an embedding column produced by the SAME embedding model — see
  ce_version_guard).

  Note the deliberate contrast with ce_attach_metadata. There, at the transform layer, metadata is
  flat: every field is just a column to carry, and citation_url has no special status. Here, at the
  serving layer, citation_url is a first-class slot in the common shape. The difference is
  intentional. A generic transform should not privilege one field; a serving contract earns a fixed
  provenance slot because a resolvable citation is part of what it promises its consumers.

  `sources` is a list of dicts; register a new source by adding one entry. `citation_url` is
  optional — omit it for a source with no resolvable link and that source's rows get NULL:
    {{ ce_knowledge_base([
        {'relation': ref('stg_tickets'), 'source_type': 'ticket',
         'source_id': 'ticket_id', 'account_key': 'account_id',
         'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
         'citation_url': 'ticket_url'},
        {'relation': ref('stg_calls'), 'source_type': 'call',
         'source_id': 'call_id', 'account_key': 'account_id',
         'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time',
         'citation_url': 'call_url'},
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
    {{ s.timestamp }} as ts,
    {% if 'citation_url' in s -%}
    cast({{ s.citation_url }} as {{ str_t }}) as citation_url
    {%- else -%}
    cast(null as {{ str_t }}) as citation_url
    {%- endif %}
from {{ s.relation }}
{% if not loop.last %}union all
{% endif %}
    {%- endfor -%}
{%- endmacro %}
