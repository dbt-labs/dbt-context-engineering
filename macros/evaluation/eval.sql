{#-
  eval(relation, prediction_column, expected_column, prompt_version=none) -> a SELECT that
  scores predicted labels against a golden/expected column and emits tidy metric rows:

      metric    | label         | value
      ----------+---------------+------
      accuracy  | __overall__   | 0.75
      precision | pain_point    | 0.66…
      recall    | pain_point    | 1.0
      …

  Scores PRE-COMPUTED prediction columns, so it runs with zero AI spend and validates on duckdb.
  Wrap it in a model and threshold a metric with a test to gate a prompt/model change. Pass
  `prompt_version` to stamp the rows and materialize as an incremental snapshot for drift tracking.

  Portable: per-label precision/recall via a full-outer join of predicted vs actual counts (no
  correlated subqueries), so the same SQL runs on all four engines.
-#}
{% macro eval(relation, prediction_column, expected_column, prompt_version=none) -%}
with _base as (
    select
        {{ prediction_column }} as pred,
        {{ expected_column }}   as expected
    from {{ relation }}
),
_overall as (
    select
        'accuracy' as metric,
        '__overall__' as label,
        cast(sum(case when pred = expected then 1 else 0 end) as {{ dbt.type_float() }})
            / nullif(count(*), 0) as value
    from _base
),
_preds as (
    select
        pred as label,
        count(*) as pred_pos,
        sum(case when pred = expected then 1 else 0 end) as tp
    from _base
    group by pred
),
_acts as (
    select expected as label, count(*) as act_pos
    from _base
    group by expected
),
_per_label as (
    select
        coalesce(p.label, a.label) as label,
        coalesce(p.tp, 0)          as tp,
        coalesce(p.pred_pos, 0)    as pred_pos,
        coalesce(a.act_pos, 0)     as act_pos
    from _preds p
    full outer join _acts a on p.label = a.label
),
_precision as (
    select 'precision' as metric, label,
           cast(tp as {{ dbt.type_float() }}) / nullif(pred_pos, 0) as value
    from _per_label
),
_recall as (
    select 'recall' as metric, label,
           cast(tp as {{ dbt.type_float() }}) / nullif(act_pos, 0) as value
    from _per_label
),
_metrics as (
    select * from _overall
    union all select * from _precision
    union all select * from _recall
)
select
    {% if prompt_version is not none %}{{ dbt_context_engineering.str_literal(prompt_version) }} as prompt_version,
    {% endif %}metric,
    label,
    value
from _metrics
{%- endmacro %}
