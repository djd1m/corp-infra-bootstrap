# Stage timing and protected prerequisite diagnostics

Library1.0.3 emits paired `timing event=start/end` records for prerequisites,
bootstrap stage entries, whole stage applies and stage-map live checks. Records
contain a bounded identifier, operation, monotonic `elapsed_ms`, child exit code
and classification. They contain no child stdout/stderr or command arguments.
Check mode writes only stdout: it creates no timing files and does not append
existing logs. Normal apply uses the existing protected script logging path.

Classifications distinguish `ok`, `condition_failed` (1), `inconclusive` (2),
`timeout` (124), `execution_error` (126/127), `signal_exit` (129–192), and
`unexpected_exit`. These are exit classifications, not explanations of a
provider/network failure. A124 result is classified but no timeout or retries
are added by instrumentation. Missing producers in the stage map retain their
existing code3/pending verdict. Failed or undetermined markers are named
`marker_failed` or `marker_inconclusive` and do not run their producers.

`require_stage` still reruns every producing live check and still exits2 when
the prerequisite cannot be accepted. It never treats a marker as proof. Its
failure now identifies the bounded producer basename and original child exit
without echoing argv or arbitrary potentially secret diagnostics. An authorized
administrator should run that producer's documented `--check` separately when
the exact failed condition is needed; do not dump its unrestricted output into
agent context or a public timing report.

Whole-stage applies include entry execution and state reconciliation. They do
not include later orchestration gates, post-stage checks or human STOP waits.
Dependency spans can be nested in stage spans: measure wall-clock critical path
by interval union, never sum all records blindly. A missing end event means an
interrupted/incomplete span, not success or zero duration. Timing alone is not
a10–15-minute onboarding acceptance test.

Before release, sync canonical library and VERSION to all five private siblings
through `scripts/sync-lib.sh`, then verify the six-copy G-09 check and consumers.
Do not publish/bootstrap1.0.3 with sibling1.0.2 copies or weaken G-09.
