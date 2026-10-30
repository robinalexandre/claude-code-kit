#!/usr/bin/env bash
# Lists the frameworks and tools the user's recently active repos depend on, one line per
# repo: "<last commit day> <repo folder> : <names>". Reads only manifests, never sources.
# Usage: stacks.sh [ROOT (default $CLAUDE_DEV_ROOT or ~/dev)] [DAYS (default 90)]
set -u
root="${1:-${CLAUDE_DEV_ROOT:-$HOME/dev}}"
days="${2:-90}"
# BSD date (macOS) takes -v, GNU date (Linux, Git Bash) takes -d.
since=$(date -v-"$days"d +%Y-%m-%d 2>/dev/null || date -d "$days days ago" +%Y-%m-%d 2>/dev/null || echo 0000-00-00)

known='^(react|react-dom|react-native|next|expo|@angular/core|rxjs|@ngrx/store|vue|nuxt|svelte|@sveltejs/kit|vite|webpack|typescript|firebase|firebase-functions|firebase-admin|fastify|express|@nestjs/core|prisma|@prisma/client|drizzle-orm|tailwindcss|jest|vitest|@playwright/test|cypress|stripe|@paddle/paddle-node-sdk|@tanstack/react-query|@reduxjs/toolkit|zod|electron|@capacitor/core|nx|turbo|@anthropic-ai/sdk|openai|@modelcontextprotocol/sdk|storybook|eslint|biome|@biomejs/biome)$'

find "$root" -maxdepth 3 -name .git -prune -print 2>/dev/null | while IFS= read -r git_dir; do
  repo=$(dirname "$git_dir")
  last=$(git -C "$repo" log -1 --format=%cs 2>/dev/null)
  [ -n "$last" ] || continue
  [ "$(printf '%s\n%s\n' "$since" "$last" | sort | head -1)" = "$since" ] || continue
  names=""
  for manifest in $(find "$repo" -maxdepth 3 -name package.json -not -path '*/node_modules/*' 2>/dev/null | head -8 | tr ' ' '?'); do
    manifest=$(printf '%s' "$manifest" | tr '?' ' ')
    names="$names $(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$manifest" 2>/dev/null | tr -d '\r' | grep -E "$known" | tr '\n' ' ')"
  done
  for py in "$repo/pyproject.toml" "$repo/requirements.txt"; do
    [ -f "$py" ] || continue
    names="$names python $(grep -oiE '(fastapi|django|flask|anthropic|pydantic|httpx|sqlalchemy|celery|pytest)' "$py" | tr 'A-Z' 'a-z' | tr '\n' ' ')"
  done
  [ -f "$repo/composer.json" ] && names="$names php $(grep -oiE '"(laravel/framework|symfony/[a-z-]+|wordpress)' "$repo/composer.json" | tr -d '"' | tr '\n' ' ')"
  find "$repo" -maxdepth 2 -name '*.xcodeproj' 2>/dev/null | grep -q . && names="$names swift ios"
  find "$repo" -maxdepth 3 -name 'build.gradle*' 2>/dev/null | grep -q . && names="$names android kotlin"
  find "$repo" -maxdepth 2 \( -name Dockerfile -o -name 'docker-compose*.yml' \) 2>/dev/null | grep -q . && names="$names docker"
  [ -f "$repo/firebase.json" ] && names="$names firebase"
  list=$(printf '%s\n' $names | sort -u | tr '\n' ' ')
  [ -n "${list// /}" ] && printf '%s %s : %s\n' "$last" "${repo#"$root"/}" "$list"
done | sort -r
