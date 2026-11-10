-- Redshift only: field must yield null, not a JSON parsing error, when the model reply is not
-- valid JSON (prose before the object, or code fences). Fail rows only.
select v
from (
    select
        {{ dbt_context_engineering.field("cast('Here is the JSON: {\"a\": 1}' as varchar(100))", 'a') }} as v,
        {{ dbt_context_engineering.field("cast('```json {\"a\": true} ```' as varchar(100))", 'a', dbt.type_boolean()) }} as b
) t
where v is not null or b is not null
