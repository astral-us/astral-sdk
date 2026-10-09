# Ready-signal movement cutoff and stopped confirmation

## Baseline and scope

Implement only the ready-signal deadline/completion boundary on
`c8762695044aa5dbe450c9eac828a54079fe4135`, in its separate baseline worktree.

The October 9 10:51 PDT run sent 29 ready pulses. Immediately before the final
pulse its measured progress was 0.079733819 m, just below the 8 cm arrival gate.
Its stop returned after five seconds; a fresh 0.093519104 m observation was
evaluated at 5.169281 s, and the overall timer correctly won under the old policy.

## Revised readiness-only policy

- Retain the five-second movement cutoff, 40 ms requested pulse budget, existing
  wheel output, 8–12 cm arrival/travel corridor, and all geometry/safety checks.
- Reserve at least 100 ms for stop/drain overhead in addition to the pulse's
  requested duration. Increase this estimate to the largest observed pulse-return
  overhead in this ready operation. It is an estimate, not a physical timing bound.
- Do not admit another pulse when that pulse plus its stop reserve would reach
  the movement cutoff. Apply the corresponding earlier expiry at transport
  admission too.
- Instead enter a one-way, motors-stopped confirmation phase. It can complete
  only from fresh evidence captured after the last confirmed stop, with all
  existing geometry, tracking, obstacle, communications, ownership and progress
  checks still passing.
- The last pulse's stop must have returned strictly before five seconds. A late
  pulse/stop cannot be rescued by a later goal observation.
- Confirmation has a fixed deadline of 5.300 s from the original ready start;
  observations cannot renew it. It sends no new motor pulse and does not renew the
  existing 2.5-second progress watchdog. No observation means no success.
- Emit `follow_ready.confirmation_started` and include confirmation state, reserve,
  and last-stop timing in failure diagnostics.

## Regression coverage

- Reproduce near-8 cm progress, reject another pulse near the movement cutoff,
  and accept a fresh 9.35 cm observation at 5.169 s after a timely stop.
- Reject confirmation after 5.300 s, insufficient progress, cached pre-stop
  evidence, unsafe lateral/travel/heading geometry, tracking loss and obstacles.
- Existing late-stop, failed-stop, cancellation, source freshness, admission and
  recovery tests remain required.

Physical validation is needed to measure whether the timely final pulse reaches
the acceptance corridor on the rover; this change does not assume the omitted
extra pulse's displacement will still occur.

## Verification results

- Near-boundary regression failed on the baseline, then passed with stopped
  confirmation. Review regressions also failed before their timing fixes.
- Ready-signal/admission suites: 67 passed.
- Full non-live baseline SDK suite: 844 passed, zero failures/skips.
- App unit suite: 33 passed, zero failures/skips.
- Signed iOS build succeeded; `git diff --check` passed.
- Review corrected stop-return timestamp capture before a potentially slow pose
  read, rechecked deadlines after confirmation reads, and preserved timing fields
  on tracking/obstacle failures. No remaining blocking review findings.
