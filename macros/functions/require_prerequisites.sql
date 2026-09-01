{#-
  Fail-fast prerequisite checks (spec §2.2). The three divergences must fail with a
  clear, actionable message — never an opaque SQL error.

  Phase 0: structural stubs for the checks that need a live connection to verify
  (e.g. Databricks runtime). BigQuery config check is real now (it's just var presence).
-#}

{% macro require_bq_model() -%}
    {#- ADVISORY, does not raise (relaxed after research). The AI.* GA functions (AI.GENERATE,
        AI.EMBED, ...) that * emit call a Gemini endpoint
        directly: NO CREATE MODEL object is required, and bq_connection is OPTIONAL (End-User
        Credentials cover interactive queries; a connection is only needed for service-account /
        long-running / batch jobs). The wrappers pass connection_id only when bq_connection is
        set. The MODEL-object requirement survives only for the legacy ML.* functions and
        self-deployed open models — out of scope for these wrappers. -#}
{%- endmacro %}


{% macro require_databricks_serverless() -%}
    {#- Databricks AI functions need serverless / DBR 18.2+; not on classic/Pro warehouses.
        Phase 0 stub: real runtime check lands when live creds exist. For now it documents
        the requirement and is a no-op so compile passes. -#}
    {#- TODO(Phase live-validation): query runtime and raise if classic/Pro. -#}
{%- endmacro %}


{% macro require_ai_functions_enabled(fn_name) -%}
    {#- Off by default (var('ai_functions_enabled', false) in dbt_project.yml) so a fresh/CI
        target can never accidentally trigger a real, billed AI call just by running `dbt
        build`. Call this from generate/classify/extract/embed/ai_agg's own outer macro (the
        adapter-agnostic entry point, before adapter.dispatch), the same injection point
        require_databricks_serverless() already uses, so anyone who calls the function
        unavoidably runs this check, not something a caller can forget to opt into.

        Gated on `execute`, the same distinction is_incremental() relies on elsewhere in this
        package: dbt's parse phase (execute=False) renders EVERY model's Jinja to build the
        manifest, regardless of --select, so an unguarded raise here breaks parsing of the
        WHOLE project the moment any one model anywhere calls an AI function, not just the
        model that does. Confirmed live: building only `split_docs chunk_docs` failed on a
        Compilation Error in `generate_text`, a model that was not selected at all, before this
        guard was added. Only the run phase (execute=True) re-renders the models actually
        selected this invocation, so gating on it scopes the check to models that are really
        about to fire, not every model that merely exists in the project. -#}
    {%- if execute and not var('ai_functions_enabled', false) -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): AI functions are disabled by default. Set var ai_functions_enabled: "
            ~ "true for this target to allow a real AI call to fire."
        ) }}
    {%- endif -%}
{%- endmacro %}


{% macro require_safe_materialization(fn_name) -%}
    {#- is_incremental() is always false for a view, so a model wrapping an AI function takes
        the "process everything" branch on every SELECT against it, not once per dbt run but
        every time anyone queries it: an unbounded, repeated cost, not a tradeoff the way
        table vs. incremental is. Same injection point and execute-gating as
        require_ai_functions_enabled, for the identical reason: config.get('materialized')
        resolves correctly from inside a macro regardless of call depth, and an unguarded raise
        here would otherwise fire during manifest parsing for every model calling this function,
        project-wide, not just the ones actually selected.

        Deliberately does NOT block 'table'. A plain table reprocesses the full corpus every run
        too, a milder form of the same problem, but table is a real, sometimes-correct choice
        (embedding_canary is table on purpose, a small fixed probe set re-embedded every build by
        design), not an unconditional mistake the way view always is. Flagging table would be a
        false positive for a legitimate pattern this package itself ships. -#}
    {%- if execute and config.get('materialized') == 'view' -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): materialized='view' recomputes this call on every query against this "
            ~ "model, an unbounded, repeated cost, not a one-time cost per dbt run. Use 'table' "
            ~ "or 'incremental' instead."
        ) }}
    {%- endif -%}
{%- endmacro %}
