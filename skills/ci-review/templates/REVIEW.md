# How to review this repository

Written by the code owners for the AI review on CI (and anyone reviewing by hand). Keep it short: when the
same review comment comes back on several PRs, move it here instead.

Proof policy: optional
<!-- required: a PR must carry proof (screenshots, a video, network captures, a test report), else "Can't tell".
     optional: judge from the code and the tests; use proof when there is some, never ask for it. -->

## What failure looks like here

<!-- The ways a change goes wrong in this repository, in one line each. Examples: docs that lie, config that
     misroutes, a field renamed that shipped app versions still read, a trigger that writes to the path it watches. -->

## Paths that need care (always high risk)

<!-- Paths and why. Keep HIGH_RISK_PATHS in .github/workflows/ai-review.yml in step with this list. -->

## Skip

<!-- Paths not to review: generated files, lockfiles, vendored code, snapshots. -->

## Findings

- Every finding names a file and a line you read; no guess from a name.
- At most 3 nits.
- The comment starts with the count ("2 important, 1 nit") and says plainly "Nothing to fix." when there is none.
