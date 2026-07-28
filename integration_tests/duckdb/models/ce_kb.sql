{{ config(materialized='table') }}
{#- Compose the two sources into one knowledge-base mart (common shape + per-source lineage).
   citation_url is present for tickets and omitted for calls on purpose — calls have no
   resolvable link in this fixture, so this exercises both the present-key and optional-key
   (NULL passthrough) branches of ce_knowledge_base, not just the present one. -#}
{{ dbt_context_engineering.ce_knowledge_base([
    {'relation': ref('source_tickets'), 'source_type': 'ticket',
     'source_id': 'ticket_id', 'account_key': 'account_id',
     'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
     'citation_url': 'ticket_url'},
    {'relation': ref('source_calls'), 'source_type': 'call',
     'source_id': 'call_id', 'account_key': 'account_id',
     'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time'}
]) }}
