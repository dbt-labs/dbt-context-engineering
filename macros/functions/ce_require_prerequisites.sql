{#-
  Fail-fast prerequisite checks (spec §2.2). The three divergences must fail with a
  clear, actionable message — never an opaque SQL error.

  Phase 0: structural stubs for the checks that need a live connection to verify
  (e.g. Databricks runtime). BigQuery config check is real now (it's just var presence).
-#}

{% macro ce_require_bq_model() -%}
    {#- ADVISORY, does not raise (relaxed after research — see docs/PARITY.md divergence #1).
        The AI.* GA functions (AI.GENERATE, AI.EMBED, ...) that ce_* emit call a Gemini endpoint
        directly: NO CREATE MODEL object is required, and ce_bq_connection is OPTIONAL (End-User
        Credentials cover interactive queries; a connection is only needed for service-account /
        long-running / batch jobs). The wrappers pass connection_id only when ce_bq_connection is
        set. The MODEL-object requirement survives only for the legacy ML.* functions and
        self-deployed open models — out of scope for these wrappers. -#}
{%- endmacro %}


{% macro ce_require_databricks_serverless() -%}
    {#- Databricks AI functions need serverless / DBR 18.2+; not on classic/Pro warehouses.
        Phase 0 stub: real runtime check lands when live creds exist. For now it documents
        the requirement and is a no-op so compile passes. -#}
    {#- TODO(Phase live-validation): query runtime and raise if classic/Pro. -#}
{%- endmacro %}
