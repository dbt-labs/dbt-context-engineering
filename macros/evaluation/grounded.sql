{#-
  grounded — generic (schema.yml) test. Asserts each row's evidence/quote actually appears in
  its source-text column, so a hallucinated quote fails the build. The package already REQUIRES an
  evidence field on extracted facts (CLAUDE.md); this is the check that the field is truthful.

  Usage:
    columns:
      - name: evidence
        tests:
          - dbt_context_engineering.grounded:
              source_text_column: source_text
              ignore_case: true            # default true
              normalize_whitespace: true   # default true
              allow_empty: false           # default false — null/blank evidence fails

  Normalization defaults ON so casing/whitespace drift in the quote is tolerated; set both false
  for byte-exact grounding. Deterministic — no warehouse, no AI. Returns failing rows only.
-#}
{% test grounded(model, column_name, source_text_column,
                    ignore_case=true, normalize_whitespace=true, allow_empty=false) %}

with _rows as (
    select
        {{ column_name }}         as _evidence,
        {{ source_text_column }}  as _source
    from {{ model }}
)
select _evidence, _source
from _rows
where
    {% if not allow_empty -%}
    (_evidence is null or length(trim(_evidence)) = 0)
    or
    {% endif -%}
    not (
        {{ dbt_context_engineering.contains(
            dbt_context_engineering.norm_text('_source',   ignore_case, normalize_whitespace),
            dbt_context_engineering.norm_text('_evidence', ignore_case, normalize_whitespace)) }}
    )

{% endtest %}
