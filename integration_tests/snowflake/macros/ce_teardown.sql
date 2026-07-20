{% macro ce_teardown() %}
    {% set objects = [
        'ce_search_sf', 'ce_embeddings_sf', 'ce_generate_sf', 'ce_extract_sf',
        'ce_signals_sf', 'ce_chunk_sf', 'ce_ai_run_log', 'ce_fixture_utterances'
    ] %}
    {% for o in objects %}
        {% set fqn = target.database ~ '.' ~ target.schema ~ '.' ~ o %}
        {% do run_query('drop table if exists ' ~ fqn) %}
        {% do log('dropped (if existed): ' ~ fqn, info=true) %}
    {% endfor %}
{% endmacro %}
