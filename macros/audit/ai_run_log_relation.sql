{#-
  Return ai_run_log at the location configured for the current target. `ref()` remains the
  dependency declaration in callers, but its rendered relation can point at production during
  state deferral when this model is not selected. The graph node's database/schema/alias are
  resolved for the active target and are not replaced by deferral.

  Return none while parsing or when the graph is unavailable; callers then use their rendered
  ref() as a parse-time fallback.
-#}
{% macro ai_run_log_relation() -%}
    {%- if execute and graph is defined and graph.nodes is defined -%}
        {%- set matches = graph.nodes.values()
            | selectattr('resource_type', 'equalto', 'model')
            | selectattr('package_name', 'equalto', 'dbt_context_engineering')
            | selectattr('name', 'equalto', 'ai_run_log')
            | list -%}
        {%- if matches | length > 0 -%}
            {%- set node = matches[0] -%}
            {{- return(api.Relation.create(
                database=node.database,
                schema=node.schema,
                identifier=node.alias,
                type='table'
            )) -}}
        {%- endif -%}
    {%- endif -%}
    {{- return(none) -}}
{%- endmacro %}
