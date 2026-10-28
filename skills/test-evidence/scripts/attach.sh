#!/bin/bash
# Uploads test evidence to a Jira issue or an Azure DevOps pull request.
#   attach.sh jira <ISSUE-KEY> <file>...         attaches the files to the issue
#   attach.sh jira-comment <ISSUE-KEY> <text>    posts a comment (Jira wiki markup: !01-login.png|thumbnail!)
#   attach.sh ado <PR-ID> <file>...              uploads the files to the PR, prints "<file><TAB><url>"; a file already
#                                                attached under the same name is reused (rename a file you changed)
#   attach.sh ado-comment <PR-ID> <markdown> [file...]
#                                                posts a comment thread on the PR, already resolved so it never blocks
#                                                the merge; the files are uploaded first and each URL:<file name> in the
#                                                markdown becomes that file's link: ![login](URL:02-login.gif)
#   attach.sh jira-get <ISSUE-KEY>               prints the issue's summary, description and any field whose name
#                                                mentions acceptance criteria, as JSON
#   attach.sh jira-criteria <ISSUE-KEY> <file>   puts <file> (wiki markup, starting with its heading) in the issue
#                                                description as its acceptance criteria section
#   attach.sh ado-criteria <PR-ID> <markdown>    the same for a PR description (Azure DevOps keeps 4000 characters)
#   attach.sh criteria-merge <text> <section>    prints <text> with its acceptance criteria section replaced by
#                                                <section>, or <section> added after the first section
# DRY_RUN=1 prints each request instead of sending it.
#
# Jira:  JIRA_BASE_URL (https://jira.example.com or https://<site>.atlassian.net), then either
#        JIRA_PAT (Server/Data Center personal access token) or JIRA_EMAIL + JIRA_API_TOKEN (Cloud).
# Azure DevOps: run it inside the repo (org, project and repo come from the origin remote) or set
#        ADO_ORG_URL (https://dev.azure.com/<org>), ADO_PROJECT, ADO_REPO.
#        Auth: AZURE_DEVOPS_PAT, else a token from `az login`.
#        Azure DevOps only takes these extensions: png gif jpg jpeg docx pptx xlsx txt pdf zip gz lyr mov mp4 csv.
set -eu -o pipefail

ADO_EXTENSIONS="png gif jpg jpeg docx pptx xlsx txt pdf zip gz lyr mov mp4 csv"

die() {
  echo "$*" >&2
  exit 1
}
native() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Windows' own curl uses the system certificate store, which corporate TLS inspection relies on.
# Its revocation check fails hard when the CRL server is unreachable; browsers treat that as best effort too.
CURL=${CURL:-curl}
CURL_OPTS=()
if [ "$CURL" = curl ] && command -v cygpath > /dev/null && [ -x "${SYSTEMROOT:-C:/Windows}/System32/curl.exe" ]; then
  CURL="${SYSTEMROOT:-C:/Windows}/System32/curl.exe"
  CURL_OPTS=(--ssl-revoke-best-effort)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# request AUTH_HEADER METHOD URL [curl args...]: the header goes through a config on stdin, never the command line.
request() {
  local auth=$1 method=$2 url=$3 code
  shift 3
  if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN $method $url $*" >&2
    echo '{}'
    return
  fi
  code=$(printf 'header = "%s"\n' "$auth" | "$CURL" ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -sS -K - -X "$method" -o "$(native "$TMP/body")" -w '%{http_code}' "$@" "$url") ||
    die "Request failed: $method $url"
  case "$code" in
    2??) cat "$TMP/body" ;;
    *) die "HTTP $code from $method $url: $(head -c 600 "$TMP/body")" ;;
  esac
}

check_name() {
  [ -f "$1" ] || die "No such file: $1"
  case "${1##*/}" in *[!A-Za-z0-9._-]*) die "Rename $1: only letters, digits, '.', '_' and '-' in file names." ;; esac
}

jira_auth() {
  [ -n "${JIRA_BASE_URL:-}" ] || die "Set JIRA_BASE_URL."
  if [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ]; then
    echo "Authorization: Basic $(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 | tr -d '\n')"
  elif [ -n "${JIRA_PAT:-}" ]; then
    echo "Authorization: Bearer $JIRA_PAT"
  else
    die "Set JIRA_PAT (Server/Data Center) or JIRA_EMAIL and JIRA_API_TOKEN (Cloud)."
  fi
}

jira() {
  local key=$1 auth f
  shift
  [ $# -gt 0 ] || die "No files given."
  for f in "$@"; do check_name "$f"; done
  auth=$(jira_auth)
  for f in "$@"; do
    request "$auth" POST "${JIRA_BASE_URL%/}/rest/api/2/issue/$key/attachments" \
      -H "X-Atlassian-Token: no-check" -F "file=@$(native "$f")" > /dev/null
    echo "attached ${f##*/} to $key"
  done
}

jira_comment() {
  local key=$1 text=$2 auth
  [ -f "$text" ] || die "No such file: $text"
  auth=$(jira_auth)
  jq -Rs '{body: .}' < "$text" > "$TMP/payload.json"
  request "$auth" POST "${JIRA_BASE_URL%/}/rest/api/2/issue/$key/comment" \
    -H "Content-Type: application/json" --data-binary "@$(native "$TMP/payload.json")" > /dev/null
  echo "commented on $key"
}

ado_target() {
  local remote
  if [ -z "${ADO_ORG_URL:-}" ] || [ -z "${ADO_PROJECT:-}" ] || [ -z "${ADO_REPO:-}" ]; then
    remote=$(git remote get-url origin 2> /dev/null) || die "Not in a git repo: set ADO_ORG_URL, ADO_PROJECT and ADO_REPO."
    # The token goes to the host built here, so the remote must match exactly: a loose
    # pattern would let https://evil.example/x.visualstudio.com/... receive it.
    local name='[A-Za-z0-9._~%-]+' org project repo
    if [[ $remote =~ ^https://([^@/]+@)?dev\.azure\.com/($name)/($name)/_git/($name)/?$ ]]; then
      org="https://dev.azure.com/${BASH_REMATCH[2]}" project=${BASH_REMATCH[3]} repo=${BASH_REMATCH[4]}
    elif [[ $remote =~ ^https://([^@/]+@)?([A-Za-z0-9-]+)\.visualstudio\.com/(DefaultCollection/)?($name)/_git/($name)/?$ ]]; then
      org="https://${BASH_REMATCH[2]}.visualstudio.com" project=${BASH_REMATCH[4]} repo=${BASH_REMATCH[5]}
    elif [[ $remote =~ ^(ssh://)?[A-Za-z0-9._-]+@ssh\.dev\.azure\.com(:|/)v3/($name)/($name)/($name)/?$ ]]; then
      org="https://dev.azure.com/${BASH_REMATCH[3]}" project=${BASH_REMATCH[4]} repo=${BASH_REMATCH[5]}
    else
      die "origin is not an Azure DevOps remote: set ADO_ORG_URL, ADO_PROJECT and ADO_REPO."
    fi
    ADO_ORG_URL=${ADO_ORG_URL:-$org}
    ADO_PROJECT=${ADO_PROJECT:-$project}
    ADO_REPO=${ADO_REPO:-$repo}
  fi
  ADO_API="${ADO_ORG_URL%/}/$ADO_PROJECT/_apis/git/repositories/${ADO_REPO%.git}"
}

ado_auth() {
  local token
  if [ -n "${AZURE_DEVOPS_PAT:-}" ]; then
    echo "Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT" | base64 | tr -d '\n')"
  elif [ -n "${DRY_RUN:-}" ]; then
    echo "Authorization: Bearer dry-run"
  else
    command -v az > /dev/null || die "Set AZURE_DEVOPS_PAT or install the Azure CLI and run az login."
    token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2> /dev/null | tr -d '\r') ||
      die "az login first, or set AZURE_DEVOPS_PAT."
    echo "Authorization: Bearer $token"
  fi
}

# Checked before any upload, so a refused file never leaves the PR with half of the files attached.
check_ado_type() {
  local ext
  ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
  case " $ADO_EXTENSIONS " in
    *" $ext "*) ;;
    *) die "Azure DevOps refuses ${1##*/}: allowed extensions are $ADO_EXTENSIONS (attach a markdown or log file as .txt)." ;;
  esac
}

ado() {
  local pr=$1 auth f name url existing
  shift
  [ $# -gt 0 ] || die "No files given."
  for f in "$@"; do
    check_name "$f"
    check_ado_type "$f"
  done
  ado_target
  auth=$(ado_auth)
  # Azure DevOps keeps one attachment per name and refuses a second upload of it.
  existing=$(request "$auth" GET "$ADO_API/pullRequests/$pr/attachments?api-version=7.1-preview.1" |
    jq -r '.value[]? | [.displayName, .url] | @tsv' | tr -d '\r')
  for f in "$@"; do
    name=${f##*/}
    url=$(printf '%s\n' "$existing" | awk -F '\t' -v name="$name" '$1 == name { print $2; exit }')
    if [ -n "$url" ]; then
      echo "$name is already attached to PR $pr: reusing it (rename the file to attach a new version)." >&2
    else
      url=$(request "$auth" POST "$ADO_API/pullRequests/$pr/attachments/$name?api-version=7.1-preview.1" \
        -H "Content-Type: application/octet-stream" --data-binary "@$(native "$f")" | jq -r '.url // empty' | tr -d '\r')
    fi
    printf '%s\t%s\n' "$name" "${url:-<dry run>}"
  done
}

ado_comment() {
  local pr=$1 md=$2 auth f
  shift 2
  [ -f "$md" ] || die "No such file: $md"
  : > "$TMP/urls.tsv"
  for f in "$@"; do
    check_name "$f"
    grep -q "URL:${f##*/}" "$md" || die "$md has no URL:${f##*/} placeholder for $f."
  done
  [ $# -eq 0 ] || ado "$pr" "$@" > "$TMP/urls.tsv"
  ado_target
  auth=$(ado_auth)
  jq -Rs --rawfile urls "$(native "$TMP/urls.tsv")" '
    reduce ($urls | split("\n")[] | select(length > 0) | split("\t")) as [$name, $url]
      (.; split("URL:" + $name) | join($url))
    | {comments: [{parentCommentId: 0, content: ., commentType: 1}], status: "closed"}' < "$md" > "$TMP/payload.json"
  if [ -z "${DRY_RUN:-}" ] && jq -r '.comments[0].content' "$TMP/payload.json" | grep -q 'URL:[A-Za-z0-9._-]'; then
    die "$md still has URL:<file> placeholders: pass those files too."
  fi
  request "$auth" POST "$ADO_API/pullRequests/$pr/threads?api-version=7.1" \
    -H "Content-Type: application/json" --data-binary "@$(native "$TMP/payload.json")" > /dev/null
  echo "commented on PR $pr"
}

# The section starts at a heading naming acceptance criteria (English or French) and ends at the next heading.
# Without one, the new section goes before the second heading, so it follows the summary; a text with fewer
# headings gets it at the end. The new section's first line sets the syntax: "h2. ..." is Jira wiki markup,
# where "# item" is a numbered list, not a heading; anything else is markdown.
criteria_merge() {
  local text=$1 section=$2
  [ -f "$text" ] || die "No such file: $text"
  [ -f "$section" ] || die "No such file: $section"
  tr -d '\r' < "$section" > "$TMP/section"
  tr -d '\r' < "$text" | awk -v sectionf="$TMP/section" '
    function heading(l) { return jira ? l ~ /^h[1-6]\.[ \t]/ : l ~ /^#+[ \t]/ }
    function criteria(l) { l = tolower(l); return heading(l) && (l ~ /acceptance criteria/ || l ~ /crit[^ ]*res d[^ ]*acceptation/) }
    BEGIN {
      while ((getline l < sectionf) > 0) section[++n] = l
      while (n > 0 && section[n] == "") n--
      jira = section[1] ~ /^h[1-6]\.[ \t]/
    }
    { line[NR] = $0 }
    END {
      start = 0
      for (i = 1; i <= NR; i++) if (criteria(line[i])) { start = i; break }
      if (start) {
        stop = NR + 1
        for (i = start + 1; i <= NR; i++) if (heading(line[i])) { stop = i; break }
      } else {
        start = NR + 1; heads = 0
        for (i = 1; i <= NR; i++) if (heading(line[i]) && ++heads == 2) { start = i; break }
        stop = start
      }
      last = start - 1
      while (last > 0 && line[last] == "") last--
      for (i = 1; i <= last; i++) print line[i]
      if (last > 0) print ""
      for (i = 1; i <= n; i++) print section[i]
      if (stop <= NR) print ""
      for (i = stop; i <= NR; i++) print line[i]
    }'
}

jira_get() {
  local key=$1 auth
  auth=$(jira_auth)
  request "$auth" GET "${JIRA_BASE_URL%/}/rest/api/2/issue/$key?expand=names" |
    jq '. as $i | {key, summary: .fields.summary, description: .fields.description,
      criteria: [($i.names // {}) | to_entries[]
        | select(.value | test("acceptance|acceptation"; "i"))
        | select($i.fields[.key] != null) | {field: .value, value: $i.fields[.key]}]}'
}

jira_criteria() {
  local key=$1 file=$2 auth
  [ -f "$file" ] || die "No such file: $file"
  auth=$(jira_auth)
  request "$auth" GET "${JIRA_BASE_URL%/}/rest/api/2/issue/$key?fields=description" |
    jq -r '.fields.description // ""' > "$TMP/description"
  criteria_merge "$TMP/description" "$file" | jq -Rs '{fields: {description: .}}' > "$TMP/payload.json"
  request "$auth" PUT "${JIRA_BASE_URL%/}/rest/api/2/issue/$key" \
    -H "Content-Type: application/json" --data-binary "@$(native "$TMP/payload.json")" > /dev/null
  echo "acceptance criteria set on $key"
}

ado_criteria() {
  local pr=$1 file=$2 auth length
  [ -f "$file" ] || die "No such file: $file"
  ado_target
  auth=$(ado_auth)
  request "$auth" GET "$ADO_API/pullRequests/$pr?api-version=7.1" | jq -r '.description // ""' > "$TMP/description"
  criteria_merge "$TMP/description" "$file" > "$TMP/merged"
  length=$(jq -Rs 'length' < "$TMP/merged")
  [ "$length" -le 4000 ] || die "The description would be $length characters; Azure DevOps keeps 4000. Shorten it."
  jq -Rs '{description: .}' < "$TMP/merged" > "$TMP/payload.json"
  request "$auth" PATCH "$ADO_API/pullRequests/$pr?api-version=7.1" \
    -H "Content-Type: application/json" --data-binary "@$(native "$TMP/payload.json")" > /dev/null
  echo "acceptance criteria set on PR $pr ($length characters)"
}

cmd=${1:-}
[ $# -ge 2 ] || {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 1
}
shift
case "$cmd" in
  jira) jira "$@" ;;
  jira-comment) jira_comment "$@" ;;
  ado) ado "$@" ;;
  ado-comment) ado_comment "$@" ;;
  jira-get) jira_get "$@" ;;
  jira-criteria) jira_criteria "$@" ;;
  ado-criteria) ado_criteria "$@" ;;
  criteria-merge) criteria_merge "$@" ;;
  *) die "Unknown command: $cmd" ;;
esac
