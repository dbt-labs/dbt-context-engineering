{#-
  teardown([dry_run=true]) — drop every table/seed this project actually builds into the
  CURRENT target's database/schema, using dbt's own build graph instead of a hand-maintained list
  (a hardcoded list drifts silently as models are added/removed — this replaces an earlier
  version that did exactly that).

  The target schema here is a shared personal dev schema, not exclusive to this project, so this
  must never touch anything outside what this project's own manifest knows about. For every
  model/seed node in the graph, only drop it if the node's own configured database/schema
  actually equal target.database/target.schema (i.e. dbt itself confirms this object belongs in
  the current target) — and even then, the drop is always issued AT target.database/target.schema
  (via api.Relation.create, which quotes correctly per adapter — plain string concatenation
  breaks on BigQuery project IDs containing hyphens), never at whatever a node's own metadata
  claims, so nothing outside the active target is ever touched even by construction.

  Defaults to a dry run (logs what it would drop, drops nothing) — pass dry_run=false to
  actually execute the drops.

  Usage:
    dbt run-operation teardown --project-dir integration_tests/snowflake
    dbt run-operation teardown --project-dir integration_tests/snowflake --args "{'dry_run':false}"
-#}
{% macro teardown(dry_run=true) %}
    {% if not execute %}
        {{ return(none) }}
    {% endif %}

    {% for node in graph.nodes.values() %}
        {% if node.resource_type in ('model', 'seed')
              and node.database == target.database
              and node.schema == target.schema %}
            {% set materialized = node.config.get('materialized', 'table') %}
            {% if materialized == 'view' %}
                {% set drop_kind = 'view' %}
            {% elif materialized == 'ephemeral' %}
                {% set drop_kind = none %}
            {% else %}
                {% set drop_kind = 'table' %}
            {% endif %}

            {% if drop_kind %}
                {% set rel = api.Relation.create(database=target.database, schema=target.schema, identifier=node.alias, type=drop_kind) %}
                {% if dry_run %}
                    {% do log('[dry run] would drop ' ~ drop_kind ~ ': ' ~ rel, info=true) %}
                {% else %}
                    {% do run_query('drop ' ~ drop_kind ~ ' if exists ' ~ rel) %}
                    {% do log('dropped (if existed): ' ~ rel, info=true) %}
                {% endif %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {% if dry_run %}
        {% do log('dry run complete -- re-run with --args "{\'dry_run\':false}" to actually drop.', info=true) %}
    {% endif %}
{% endmacro %}
