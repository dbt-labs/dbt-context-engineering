{{ config(materialized='table') }}
{#- Compose the two sources into one knowledge-base mart (common shape + per-source lineage).
   citation_url and classification are both present for tickets and both omitted for calls on
   purpose: calls have no resolvable link and no classify() label in this fixture, so this
   exercises both the present-key and optional-key (NULL passthrough) branches of knowledge_base
   for each independently-optional column, not just the present one. -#}
{{ dbt_context_engineering.knowledge_base([
    {'relation': ref('source_tickets'), 'source_type': 'ticket',
     'source_id': 'ticket_id', 'account_key': 'account_id',
     'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
     'citation_url': 'ticket_url', 'classification': 'category'},
    {'relation': ref('source_calls'), 'source_type': 'call',
     'source_id': 'call_id', 'account_key': 'account_id',
     'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time'}
]) }}
