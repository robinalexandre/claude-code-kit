#!/bin/bash
# Masks credentials in a text dump (headers, request/response bodies, logs) before it is shared.
#   redact.sh <in> [out]          writes to out, or prints
#   redact.sh --emails <in> [out] also masks email addresses
# It masks what looks like a secret; it can't know your app's own secret fields, so still read the result.
set -eu
emails=0
if [ "${1:-}" = --emails ]; then
  emails=1
  shift
fi
[ $# -ge 1 ] || {
  echo "usage: redact.sh [--emails] <in> [out]" >&2
  exit 1
}
in=$1
# Redirecting to /dev/stdout would truncate a file that stdout already points to.
[ $# -ge 2 ] && exec > "$2"

EMAILS=$emails perl -pe '
  BEGIN { $k = qr/(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-functions-key|ocp-apim-subscription-key|x-csrf-token|x-xsrf-token)/i }
  s/^(\s*["\x27]?$k["\x27]?\s*[:=]\s*["\x27]?)[^"\x27\r\n]+/$1\[REDACTED\]/gm;
  s/(["\x27]$k["\x27]\s*:\s*["\x27])[^"\x27]*/$1\[REDACTED\]/g;
  s/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*/[REDACTED_JWT]/g;
  s/(["\x27]?(?:access_token|refresh_token|id_token|client_secret|clientSecret|password|passwd|secret|api_?key|apiKey|private_key|connection_?string|sas_?token)["\x27]?\s*[:=]\s*["\x27]?)[^"\x27,&\s}]+/$1\[REDACTED\]/gi;
  s/([?&](?:code|token|access_token|id_token|sig|signature|key|client_secret|password|sv|se|sp)=)[^&\s"\x27<>]+/$1\[REDACTED\]/gi;
  s/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/$1 [REDACTED]/g;
  s/(AccountKey|SharedAccessKey|Password|Pwd)=[^;"\x27\s]+/$1=[REDACTED]/gi;
  s/[\w.+-]+@[\w-]+\.[\w.-]+/[REDACTED_EMAIL]/g if $ENV{EMAILS};
' "$in"
