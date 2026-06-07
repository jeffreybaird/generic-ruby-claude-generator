#!/usr/bin/env bash
#
# new_ruby_app.sh — bootstrap a Rails 8 web app pre-wired for the skill docs in
# this repo.
#
# Generates the app, adds the gems the skill docs assume, rewrites every
# MyApp / my_app reference in CLAUDE.md and .claude/*.md to the new app's names,
# and drops those docs into the project.
#
# Usage:
#   ./new_ruby_app.sh <app_name> [options]
#
# Arguments:
#   <app_name>            App name, lowercase snake_case (e.g. blog_engine).
#                         The module/class name is the camelized form (BlogEngine).
#
# Options:
#   --path <dir>          Parent directory to create the app in (default: cwd).
#   --template <dir>      Directory holding CLAUDE.md + .claude/ (default: this
#                         script's directory).
#   --no-deps             Pass --skip-bundle to `rails new`.
#   --no-git              Skip git init / the initial commit.
#   -h, --help            Show this help.
#
# Examples:
#   ./new_ruby_app.sh blog_engine
#   ./new_ruby_app.sh shopfront --path ~/src
#
# Requirements:
#   - Ruby 3.3+ and Bundler on PATH.
#   - The rails gem (`gem install rails`).
#   - bash, perl, git (standard on macOS/Linux), and PostgreSQL to run the app.
#
set -euo pipefail

# ---- pretty output -----------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; RST=""
fi
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!!%s  %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- defaults ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"
TARGET_PARENT="$PWD"
DO_DEPS=1
DO_GIT=1
APP_NAME=""

# ---- arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --path) TARGET_PARENT="${2:?--path needs a value}"; shift 2 ;;
    --template) TEMPLATE_DIR="${2:?--template needs a value}"; shift 2 ;;
    --no-deps) DO_DEPS=0; shift ;;
    --no-git) DO_GIT=0; shift ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$APP_NAME" ]] || die "unexpected extra argument: $1"
      APP_NAME="$1"; shift ;;
  esac
done

[[ -n "$APP_NAME" ]] || { warn "missing <app_name>"; usage 1; }

# ---- validation --------------------------------------------------------------
[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]*$ ]] \
  || die "app name '$APP_NAME' must be lowercase snake_case ([a-z][a-z0-9_]*)."

command -v ruby  >/dev/null 2>&1 || die "ruby not found — install Ruby 3.3+ first."
command -v bundle >/dev/null 2>&1 || die "bundler not found — run: gem install bundler"
command -v rails >/dev/null 2>&1 || die "rails not found — run: gem install rails"

[[ -f "$TEMPLATE_DIR/CLAUDE.md" ]] \
  || die "no CLAUDE.md in template dir '$TEMPLATE_DIR' (override with --template)."
[[ -d "$TEMPLATE_DIR/.claude" ]] \
  || die "no .claude/ in template dir '$TEMPLATE_DIR' (override with --template)."

APP_DIR="$TARGET_PARENT/$APP_NAME"
[[ -e "$APP_DIR" ]] && die "target already exists: $APP_DIR"

# ---- derive module name (camelize) -------------------------------------------
to_module() {
  local s="$1" out="" part first rest
  local IFS='_'
  for part in $s; do
    first="$(printf '%s' "${part:0:1}" | tr '[:lower:]' '[:upper:]')"
    rest="${part:1}"
    out+="${first}${rest}"
  done
  printf '%s' "$out"
}
MODULE="$(to_module "$APP_NAME")"

info "App name : ${BOLD}$APP_NAME${RST}   Module: ${BOLD}$MODULE${RST}"
info "Location : ${BOLD}$APP_DIR${RST}"

# ---- gems the skill docs assume ----------------------------------------------
# Appended to the generated Gemfile (a Gemfile is just Ruby, so appending is safe).
common_gem_block() {
  cat <<'GEMS'

# --- added by new_ruby_app.sh (see CLAUDE.md — skill docs) ---
gem "dry-monads", "~> 1.6"   # Result types for service objects
gem "pundit", "~> 2.3"       # authorization policies
gem "pagy", "~> 9.0"         # pagination
gem "faraday", "~> 2.0"      # HTTP client
gem "faraday-retry", "~> 2.0"
gem "discard", "~> 1.3"      # soft deletes
gem "flipper", "~> 1.3"      # feature flags
GEMS
}

# ============================================================================
#  Rails
# ============================================================================
generate_rails() {
  local flags=(--database=postgresql --css=tailwind)
  [[ "$DO_DEPS" -eq 1 ]] || flags+=(--skip-bundle)
  [[ "$DO_GIT"  -eq 1 ]] || flags+=(--skip-git)
  info "Running: rails new $APP_NAME ${flags[*]}"
  ( cd "$TARGET_PARENT" && rails new "$APP_NAME" "${flags[@]}" )
  [[ -d "$APP_DIR" ]] || die "rails new did not produce $APP_DIR"

  # Append common gems + Rails-only flipper adapter and test stack.
  {
    common_gem_block
    cat <<'GEMS'
gem "flipper-active_record", "~> 1.3"

group :development, :test do
  gem "rspec-rails", "~> 7.0"
  gem "factory_bot_rails", "~> 6.4"
end

group :test do
  gem "capybara"
  gem "webmock"
  gem "vcr"
end

group :development do
  gem "bundler-audit", require: false
end
GEMS
  } >> "$APP_DIR/Gemfile"
  info "Appended skill-doc gems to Gemfile."

  if [[ "$DO_DEPS" -eq 1 ]]; then
    info "Installing gems (bundle install)..."
    ( cd "$APP_DIR" && bundle install )
  else
    warn "Skipped bundle install (--no-deps)."
  fi
}

# ---- generate ----------------------------------------------------------------
generate_rails

# ---- copy + rewrite the skill docs -------------------------------------------
info "Copying skill docs into project and rewriting names..."
mkdir -p "$APP_DIR/.claude"
cp "$TEMPLATE_DIR/CLAUDE.md" "$APP_DIR/CLAUDE.md"

DOC_COUNT=0
shopt -s nullglob
for src in "$TEMPLATE_DIR"/.claude/*.md; do
  base="$(basename "$src")"
  [[ "$base" == "SKILL-AUDIT-REPORT.md" ]] && continue
  cp "$src" "$APP_DIR/.claude/$base"
  DOC_COUNT=$((DOC_COUNT + 1))
done
shopt -u nullglob

# Rewrite placeholders. Plain global replace handles compounds: MyApp→$MODULE
# also fixes MyApp::Foo; my_app→$APP_NAME also fixes :my_app and my_app/paths.
REWRITTEN=0
while IFS= read -r -d '' file; do
  MODULE="$MODULE" APP_NAME="$APP_NAME" \
    perl -pi -e 's/\QMyApp\E/$ENV{MODULE}/g; s/\Qmy_app\E/$ENV{APP_NAME}/g;' "$file"
  REWRITTEN=$((REWRITTEN + 1))
done < <(find "$APP_DIR/CLAUDE.md" "$APP_DIR/.claude" -name '*.md' -type f -print0)

info "Placed ${BOLD}$((DOC_COUNT + 1))${RST} docs (CLAUDE.md + $DOC_COUNT skill files), rewrote $REWRITTEN."

# ---- git init + initial commit -----------------------------------------------
# Non-fatal: a missing git binary or unconfigured user.name/email must not abort.
if [[ "$DO_GIT" -eq 1 ]]; then
  if command -v git >/dev/null 2>&1; then
    info "Committing the bootstrapped app + skill docs..."
    (
      cd "$APP_DIR"
      git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q
      git add -A
      git commit -q -m "chore: initial Rails app + Claude Code skill docs (see CLAUDE.md)"
    ) || warn "git commit skipped (configure user.name/email?)."
  else
    warn "git not found — skipping commit (pass --no-git to silence)."
  fi
fi

# ---- next steps --------------------------------------------------------------
cat <<EOF

${GRN}${BOLD}Done.${RST} ${BOLD}$MODULE${RST} (Rails) is ready at ${BOLD}$APP_DIR${RST}

${BOLD}Next steps${RST}:
  cd $APP_NAME
EOF

cat <<EOF
  bin/rails db:prepare
  ${DIM}# Authorization + auth scaffolding the docs assume:${RST}
  bin/rails generate authentication      ${DIM}# Rails 8 built-in${RST}
  ${DIM}# rubocop / brakeman / bundler-audit are wired for CI (.claude/testing.md)${RST}
  bin/rails server
EOF

cat <<EOF

Skill docs live in ${BOLD}$APP_NAME/CLAUDE.md${RST} and ${BOLD}$APP_NAME/.claude/${RST}.
EOF
