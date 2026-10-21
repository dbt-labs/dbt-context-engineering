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

  confidence_column (optional): a calibration check for a decision model's confidence (issue #29).
  Adds `accuracy_by_confidence` and `count_by_confidence` rows per confidence bucket, labeled
  '0.0-0.5', '0.5-0.7', '0.7-0.8', '0.8-0.9', '0.9-1.0', and 'unscored' for a null confidence.
  Use it on a golden set to choose the threshold above which accuracy meets your bar.

  Portable: per-label precision/recall via a full-outer join of predicted vs actual counts (no
  correlated subqueries), so the same SQL runs on all four engines.
-#}
{% macro eval(relation, prediction_column, expected_column, prompt_version=none, confidence_column=none) -%}
with _base as (
    select
        {{ prediction_column }} as pred,
        {{ expected_column }}   as expected{% if confidence_column is not none %},
        {{ confidence_column }} as conf{% endif %}
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
{%- if confidence_column is not none %}
_buckets as (
    select
        pred,
        expected,
        case
            when conf is null then 'unscored'
            when conf >= 0.9 then '0.9-1.0'
            when conf >= 0.8 then '0.8-0.9'
            when conf >= 0.7 then '0.7-0.8'
            when conf >= 0.5 then '0.5-0.7'
            else '0.0-0.5'
        end as label
    from _base
),
_by_confidence as (
    select 'accuracy_by_confidence' as metric, label,
           cast(sum(case when pred = expected then 1 else 0 end) as {{ dbt.type_float() }})
               / nullif(count(*), 0) as value
    from _buckets
    group by label
    union all
    select 'count_by_confidence' as metric, label, cast(count(*) as {{ dbt.type_float() }}) as value
    from _buckets
    group by label
),
{%- endif %}
_metrics as (
    select * from _overall
    union all select * from _precision
    union all select * from _recall
    {%- if confidence_column is not none %}
    union all select * from _by_confidence
    {%- endif %}
)
select
    {% if prompt_version is not none %}{{ dbt_context_engineering.str_literal(prompt_version) }} as prompt_version,
    {% endif %}metric,
    label,
    value
from _metrics
{%- endmacro %}
