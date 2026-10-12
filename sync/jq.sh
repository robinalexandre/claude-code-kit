# Sourced by sync.sh and json-merge.sh: defines a jq function.
# A mise shim costs about 2 s per call on Windows, enough to hit hook timeouts,
# so the binary it would run is called directly.
# Git Bash on Windows: native jq.exe writes CRLF unless -b is passed.
JQ_BIN=$(command -v jq)
case "$JQ_BIN" in
  */[Mm]ise/shims/*)
    for jq_candidate in "${JQ_BIN%/shims/*}"/installs/jq/*/jq.exe "${JQ_BIN%/shims/*}"/installs/jq/*/jq "${JQ_BIN%/shims/*}"/installs/jq/*/bin/jq; do
      [ -f "$jq_candidate" ] && [ -x "$jq_candidate" ] && JQ_BIN=$jq_candidate
    done
    unset jq_candidate
    ;;
esac
if command -v cygpath > /dev/null 2>&1; then
  jq() { "${JQ_BIN:-jq}" -b "$@"; }
else
  jq() { "${JQ_BIN:-jq}" "$@"; }
fi
