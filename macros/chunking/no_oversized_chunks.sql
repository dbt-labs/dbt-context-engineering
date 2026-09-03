{#-
  no_oversized_chunks — generic (schema.yml) test for chunk()'s exceeds_target column. Fails the
  build if any row has exceeds_target = true, so an oversized chunk (bounded only by the largest
  single unit, since units are never split, ADR-0002/ADR-0029) is a red test a consumer sees
  immediately, not a column they have to remember to query themselves.

  Deliberately a shipped test rather than a documented recipe: dbt's built-in accepted_values has
  finicky boolean-representation behavior across engines, and this package has no dbt_utils
  dependency anywhere else (content_hash, row_value_not_in, str_literal are all custom-built), so
  reaching for dbt_utils.expression_is_true here would be the first dependency of its kind.

  Not the default. exceeds_target is a data-quality signal about the SOURCE corpus (a unit larger
  than target_tokens), not a package-level correctness bug, so failing on it is an opt-in a
  consumer chooses for their own corpus, the same way grounded (Phase 7) is opt-in.

  Recourse when this fires, in order: chunk() never splits a unit (ADR-0002), so the fix lives
  upstream, before chunk() ever sees the oversized unit, never inside chunk() itself.
    1. Run the offending text through split_sentences() (or a similar finer splitter) before
       calling chunk(), so one oversized unit becomes several units chunk() packs normally. The
       common case: a whole paragraph or pasted block arriving as one unit.
    2. If units are already as fine-grained as reasonable and still exceed target, raise
       target_tokens to fit the corpus's real unit-size distribution.
    3. If a unit is still oversized after that (a genuinely unsplittable block), there is no
       further recourse inside this package; chunk() deliberately never splits a unit, and
       ADR-0029 rejected a compile-time error here since unit sizes are only known at run time.
       Filter the row out of what reaches embed(), route it to a separate remediation path, or
       accept and truncate it, a consumer-side choice this package cannot make on your behalf.

  Usage:
    columns:
      - name: exceeds_target
        tests:
          - dbt_context_engineering.no_oversized_chunks
-#}
{% test no_oversized_chunks(model, column_name) %}

select *
from {{ model }}
where {{ column_name }}

{% endtest %}
