{#-
  assert_canary_calibration_sensitivity: two assertions in one, against canary_calibration's
  known-cosine fixtures.

  1. Numerical correctness: canary_cosine_similarity's observed_similarity must match each row's
     closed-form expected_similarity within float tolerance.
  2. Threshold sensitivity: embedding_canary_similarity_threshold (ADR-0026, default 0.999) must
     NOT trip at 0.9999 (comfortably above) and MUST trip at 0.99 (comfortably below). This is the
     check embedding_canary's own duckdb tier cannot do on its own -- it compares a fixed stand-in
     vector to itself, so its similarity is always exactly 1.0 and passes at any threshold,
     including an inverted comparison or a broken default.

  Any row failing either check fails this test.
-#}

{% set threshold = var('embedding_canary_similarity_threshold', 0.999) %}

select *
from {{ ref('canary_calibration') }}
where abs(observed_similarity - expected_similarity) > 0.000001
   or (probe_id = 'calib_9999' and observed_similarity <  {{ threshold }})
   or (probe_id = 'calib_99'   and observed_similarity >= {{ threshold }})
