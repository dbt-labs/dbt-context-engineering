{#-
  knowledge_base(sources) — compose multiple pre-embedded source tables (tickets, calls, notes,
  emails, …) into one queryable mart with a common shape, so a single vector_search answers
  "everything about account X" across systems (spec §7, Phase 6).

  Each source is normalized to: source_type, source_id, account_key, text, embedding, ts,
  citation_url, classification. Per-source lineage (source_type + source_id) is preserved into
  every row, so a retrieval result can cite which system and row it came from; citation_url
  (optional per source) is a single resolvable link back to that source object (a Notion page, a
  Salesforce record, a ticket URL), the mechanism for an AI consumer to cite its source, not just
  identify it. classification (optional per source) carries a source's classify() label, the same
  optional-slot treatment as citation_url: pass the column name a source already computed
  upstream (knowledge_base never calls classify() itself, same relationship it has to embed()),
  omit it and the source's rows get NULL. The union is pure SQL and portable; the embeddings
  themselves come from embed upstream (each source must already carry an embedding column
  produced by the SAME embedding model, see version_guard).

  Note the deliberate contrast with attach_metadata. There, at the transform layer, metadata is
  flat: every field is just a column to carry, and citation_url has no special status. Here, at the
  serving layer, citation_url is a first-class slot in the common shape. The difference is
  intentional. A generic transform should not privilege one field; a serving contract earns a fixed
  provenance slot because a resolvable citation is part of what it promises its consumers.

  `sources` is a list of dicts; register a new source by adding one entry. `citation_url` and
  `classification` are each independently optional, omit either for a source with no resolvable
  link / no classify() label and that source's rows get NULL for the omitted one:
    {{ knowledge_base([
        {'relation': ref('stg_tickets'), 'source_type': 'ticket',
         'source_id': 'ticket_id', 'account_key': 'account_id',
         'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
         'citation_url': 'ticket_url', 'classification': 'category'},
        {'relation': ref('stg_calls'), 'source_type': 'call',
         'source_id': 'call_id', 'account_key': 'account_id',
         'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time',
         'citation_url': 'call_url'},
    ]) }}

  Returns a SELECT (union across sources). Use as a model body; then search it with
  vector_search(..., filter="account_key = '<acct>'").

  Also always emits source_key and content_hash. source_key is source_type || '::' || source_id,
  the composite natural key synthesized into one column, the same technique chunk_id already uses
  for partition_key + chunk_seq: it is computed in its own CTE rather than as a same-SELECT alias
  (the BigQuery trap chunk.sql's own comments document), so it exists as a real, bare column name
  on both the fresh side and on `this`, which is what lets incremental_delta_predicate compare them
  symmetrically without a same-column-name mismatch.

  content_hash is a hash of every non-key output column (account_key, text, ts, citation_url,
  classification), computed inside this macro rather than by the caller, the same macro-owned
  principle chunk() and attach_metadata() already apply. It deliberately does NOT cover embedding:
  the vector is never cast elsewhere in this macro either (a VECTOR/ARRAY cast is itself
  engine-specific and would not repair a genuine dimension/model mismatch), and hashing one would
  reintroduce that same non-portability for a narrow benefit. Consequence, not oversight: a source
  row whose upstream embedding changes with its text held constant (a model/version bump upstream,
  content_hash there covers exactly this per ADR-0023) is not caught as dirty here on that basis
  alone. In practice a model/version bump also tends to arrive with other upstream metadata
  changes, but that is not a guarantee, so this is a known, explicit limitation, not a proven-safe
  one.

  When materialized='incremental', each source's own arm is filtered to new-or-changed rows via
  incremental_delta_predicate('source_key', content_hash_column='content_hash'), applied per
  source arm before the union, not as an outer wrap-and-filter around the whole union. A
  wrap-and-filter gets correctness (no duplicate rows) but not the compute savings that are
  usually the point of going incremental: every source's SELECT would still fully scan, cast, and
  union before an outer WHERE ever narrowed anything. Filtering inside each arm means an untouched
  source contributes nothing to scan past its own delta check.

  Safe to merge on source_key: like attach_metadata and unlike chunk(), knowledge_base never
  invents or renumbers a key, every row maps 1:1 to exactly one upstream source row, so a
  source_key knowledge_base receives matches at most one stored row.

  A source row deleted entirely from its upstream relation leaves a stale knowledge_base row
  behind indefinitely: absent from the batch, so invisible to incremental_delta_predicate, the
  same gap chunk() and attach_metadata() have. Not fixed with deletion logic: a delete driven by
  absence can't tell "genuinely gone upstream" from "source came back empty due to a transient
  failure," and the latter would wipe an entire source's rows. Surfaced instead with a
  relationships test between this model and each source's current output, see
  orphan_kb/orphan_kb_valid_keys in TESTING.md 4.4.
-#}
{% macro knowledge_base(sources) -%}
    {%- if sources is none or (sources | length) == 0 -%}
        {{ exceptions.raise_compiler_error("knowledge_base: `sources` must be a non-empty list of source dicts.") }}
    {%- endif -%}
    {%- set required = ['relation', 'source_type', 'source_id', 'account_key', 'text', 'embedding', 'timestamp'] -%}
    {%- set str_t = dbt.type_string() -%}
    {%- set ts_t = dbt.type_timestamp() -%}
    {%- for s in sources -%}
        {#- capture the SOURCE's position before the inner loop shadows loop.index with the key's -#}
        {%- set source_num = loop.index -%}
        {%- for k in required -%}
            {%- if k not in s -%}
                {{ exceptions.raise_compiler_error("knowledge_base: source #" ~ source_num ~ " is missing key '" ~ k ~ "'.") }}
            {%- endif -%}
        {%- endfor -%}
{{ "with" if source_num == 1 }} _ce_src_{{ source_num }}_base as (
    select
        {{ "'" ~ s.source_type ~ "'" }} as source_type,
        cast({{ s.source_id }} as {{ str_t }})    as source_id,
        cast({{ s.account_key }} as {{ str_t }})  as account_key,
        {#- text and ts are cast to a common type so heterogeneous sources UNION cleanly — a strict
            engine (BigQuery) rejects a UNION ALL whose Nth columns differ (e.g. one source's
            timestamp is DATE, another's is TIMESTAMP). embedding is intentionally NOT cast: every
            source must already carry an embedding from the SAME model (see version_guard), so the
            column type is homogeneous by that invariant, and casting a VECTOR/ARRAY is itself
            engine-specific and would not repair a genuine dimension/model mismatch anyway. -#}
        cast({{ s.text }} as {{ str_t }})         as text,
        {{ s.embedding }} as embedding,
        cast({{ s.timestamp }} as {{ ts_t }})     as ts,
        {% if 'citation_url' in s -%}
        cast({{ s.citation_url }} as {{ str_t }}) as citation_url,
        {%- else -%}
        cast(null as {{ str_t }}) as citation_url,
        {%- endif %}
        {% if 'classification' in s -%}
        cast({{ s.classification }} as {{ str_t }}) as classification
        {%- else -%}
        cast(null as {{ str_t }}) as classification
        {%- endif %}
    from {{ s.relation }}
),
_ce_src_{{ source_num }}_keyed as (
    select
        *,
        source_type || '::' || source_id as source_key,
        {{ dbt_context_engineering.content_hash(
            ["coalesce(account_key, '')", "coalesce(text, '')",
             "coalesce(cast(ts as " ~ str_t ~ "), '')", "coalesce(citation_url, '')",
             "coalesce(classification, '')"] | join(" || '|' || ")
        ) }} as content_hash
    from _ce_src_{{ source_num }}_base
){% if not loop.last %},
{% endif %}
    {%- endfor %}

{%- set delta = dbt_context_engineering.incremental_delta_predicate('source_key', content_hash_column='content_hash') %}
{% for s in sources %}
select * from _ce_src_{{ loop.index }}_keyed
{%- if delta %}
where {{ delta }}
{%- endif %}
{% if not loop.last %}union all
{% endif %}
{%- endfor -%}
{%- endmacro %}
