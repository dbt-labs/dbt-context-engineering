{#- Row-count assertion for dev_sample_filter (see sample_filtered.sql). Reads the same var the
    macro reads, so one `dbt build` covers the unset case (full corpus, macro emits nothing) and a
    `--vars '{ai_sample_rows: N}'` rebuild covers the capped case. Fails with both counts visible
    rather than a bare row, so a mismatch says what it was and what it should have been. -#}
{%- set n = var('ai_sample_rows', none) -%}

with actual as (
    select count(*) as n from {{ ref('sample_filtered') }}
),
expected as (
    {% if n is none -%}
    select count(*) as n from {{ ref('fixture_utterances') }}
    {%- else -%}
    select {{ n }} as n from {{ ref('fixture_utterances') }} limit 1
    {%- endif %}
)
select a.n as actual_rows, e.n as expected_rows
from actual a
cross join expected e
where a.n != e.n
