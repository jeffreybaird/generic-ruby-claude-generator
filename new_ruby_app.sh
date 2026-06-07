#!/usr/bin/env bash
#
# new_ruby_app.sh — bootstrap a Ruby web app (Rails 8 or Sinatra 4) pre-wired for
# the skill docs in this repo.
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
#   --framework <fw>      "rails" (default) or "sinatra".
#   --path <dir>          Parent directory to create the app in (default: cwd).
#   --template <dir>      Directory holding CLAUDE.md + .claude/ (default: this
#                         script's directory).
#   --no-deps             Skip `bundle install` (Sinatra) / pass --skip-bundle (Rails).
#   --no-git              Skip git init / the initial commit.
#   -h, --help            Show this help.
#
# Examples:
#   ./new_ruby_app.sh blog_engine
#   ./new_ruby_app.sh blog_engine --framework sinatra
#   ./new_ruby_app.sh shopfront --framework rails --path ~/src
#
# Requirements:
#   - Ruby 3.3+ and Bundler on PATH.
#   - Rails:   the rails gem (`gem install rails`) for --framework rails.
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

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- defaults ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"
TARGET_PARENT="$PWD"
FRAMEWORK="rails"
DO_DEPS=1
DO_GIT=1
APP_NAME=""

# ---- arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --framework) FRAMEWORK="${2:?--framework needs a value}"; shift 2 ;;
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
[[ "$FRAMEWORK" == "rails" || "$FRAMEWORK" == "sinatra" ]] \
  || die "--framework must be 'rails' or 'sinatra' (got '$FRAMEWORK')."

# ---- validation --------------------------------------------------------------
[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]*$ ]] \
  || die "app name '$APP_NAME' must be lowercase snake_case ([a-z][a-z0-9_]*)."

command -v ruby  >/dev/null 2>&1 || die "ruby not found — install Ruby 3.3+ first."
command -v bundle >/dev/null 2>&1 || die "bundler not found — run: gem install bundler"
if [[ "$FRAMEWORK" == "rails" ]]; then
  command -v rails >/dev/null 2>&1 || die "rails not found — run: gem install rails"
fi

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

info "App name : ${BOLD}$APP_NAME${RST}   Module: ${BOLD}$MODULE${RST}   Framework: ${BOLD}$FRAMEWORK${RST}"
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

# ============================================================================
#  Sinatra — hand-scaffolded skeleton (no generator exists)
# ============================================================================
generate_sinatra() {
  info "Scaffolding Sinatra skeleton..."
  mkdir -p "$APP_DIR"/{config,lib/"$APP_NAME",db/migrate,views,public,spec}

  cat > "$APP_DIR/Gemfile" <<GEMS
source "https://rubygems.org"

gem "sinatra", "~> 4.0"
gem "sinatra-contrib", "~> 4.0"
gem "rackup", "~> 2.1"
gem "puma", "~> 6.4"
gem "activerecord", "~> 8.0"
gem "sinatra-activerecord", "~> 2.0"
gem "pg", "~> 1.5"
gem "rake"
gem "sidekiq", "~> 7.0"
gem "dotenv", "~> 3.1"
$(common_gem_block | tail -n +2)

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.1"
  gem "factory_bot", "~> 6.4"
end

group :test do
  gem "capybara", "~> 3.40"
  gem "webmock", "~> 3.0"
  gem "vcr", "~> 6.0"
end

group :development do
  gem "rubocop", require: false
  gem "brakeman", require: false
  gem "bundler-audit", require: false
end
GEMS

  echo "3.3.4" > "$APP_DIR/.ruby-version"

  cat > "$APP_DIR/app.rb" <<RUBY
require "bundler/setup"
Bundler.require(:default, (ENV["APP_ENV"] || "development").to_sym)
require_relative "lib/${APP_NAME}"
RUBY

  cat > "$APP_DIR/config.ru" <<RUBY
require_relative "app"
run ${MODULE}::App
RUBY

  cat > "$APP_DIR/lib/${APP_NAME}.rb" <<RUBY
require "sinatra/base"
require "sinatra/activerecord"

# Top-level namespace for the application.
# Domain logic lives in service objects under lib/${APP_NAME}/, returning Result
# types (dry-monads). Routes stay thin. See CLAUDE.md and .claude/.
module ${MODULE}
  class App < Sinatra::Base
    register Sinatra::ActiveRecordExtension

    configure do
      set :root, File.expand_path("..", __dir__)
      set :views, File.expand_path("../views", __dir__)
      set :public_folder, File.expand_path("../public", __dir__)
    end

    # Health check (see .claude/deployment.md). Kept dependency-free so it
    # answers even if the database is briefly unavailable.
    get "/up" do
      "OK"
    end

    get "/" do
      erb :index
    end
  end
end
RUBY

  cat > "$APP_DIR/config/database.yml" <<'YAML'
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("DB_POOL", 5) %>
  host: <%= ENV.fetch("DATABASE_HOST", "localhost") %>
  username: <%= ENV.fetch("DATABASE_USER", "postgres") %>
  password: <%= ENV.fetch("DATABASE_PASSWORD", "") %>

development:
  <<: *default
  database: APPNAME_development

test:
  <<: *default
  database: APPNAME_test

production:
  <<: *default
  url: <%= ENV["DATABASE_URL"] %>
YAML
  # Substitute the app name into the YAML (kept out of the quoted heredoc above).
  perl -pi -e "s/APPNAME/${APP_NAME}/g" "$APP_DIR/config/database.yml"

  cat > "$APP_DIR/config/puma.rb" <<'RUBY'
threads_count = ENV.fetch("MAX_THREADS", 5).to_i
threads threads_count, threads_count
port ENV.fetch("PORT", 4567)
environment ENV.fetch("APP_ENV", "development")
RUBY

  cat > "$APP_DIR/Rakefile" <<RUBY
require_relative "app"
require "sinatra/activerecord/rake"
RUBY

  cat > "$APP_DIR/views/layout.erb" <<HTML
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${MODULE}</title>
  </head>
  <body>
    <main data-testid="app-root">
      <%= yield %>
    </main>
  </body>
</html>
HTML

  cat > "$APP_DIR/views/index.erb" <<HTML
<h1>${MODULE}</h1>
<p data-testid="welcome">It works. See CLAUDE.md and .claude/ for conventions.</p>
HTML

  cat > "$APP_DIR/.rspec" <<'TXT'
--require spec_helper
--format documentation
TXT

  cat > "$APP_DIR/spec/spec_helper.rb" <<RUBY
ENV["APP_ENV"] = "test"
require_relative "../app"
require "rack/test"

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end

def app
  ${MODULE}::App
end
RUBY

  cat > "$APP_DIR/spec/app_spec.rb" <<RUBY
RSpec.describe ${MODULE}::App do
  it "answers the health check" do
    get "/up"
    expect(last_response).to be_ok
    expect(last_response.body).to eq("OK")
  end

  it "renders the home page" do
    get "/"
    expect(last_response).to be_ok
    expect(last_response.body).to include("welcome")
  end
end
RUBY

  cat > "$APP_DIR/.gitignore" <<'TXT'
/.bundle
/vendor/bundle
/tmp
/log/*.log
/coverage
.env
.DS_Store
TXT

  touch "$APP_DIR/db/migrate/.keep" "$APP_DIR/public/.keep"

  if [[ "$DO_DEPS" -eq 1 ]]; then
    info "Installing gems (bundle install)..."
    ( cd "$APP_DIR" && bundle install )
  else
    warn "Skipped bundle install (--no-deps)."
  fi
}

# ---- generate ----------------------------------------------------------------
if [[ "$FRAMEWORK" == "rails" ]]; then generate_rails; else generate_sinatra; fi

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
      git commit -q -m "chore: initial Ruby ($FRAMEWORK) app + Claude Code skill docs (see CLAUDE.md)"
    ) || warn "git commit skipped (configure user.name/email?)."
  else
    warn "git not found — skipping commit (pass --no-git to silence)."
  fi
fi

# ---- next steps --------------------------------------------------------------
cat <<EOF

${GRN}${BOLD}Done.${RST} ${BOLD}$MODULE${RST} ($FRAMEWORK) is ready at ${BOLD}$APP_DIR${RST}

${BOLD}Next steps${RST}:
  cd $APP_NAME
EOF

if [[ "$FRAMEWORK" == "rails" ]]; then
  cat <<EOF
  bin/rails db:prepare
  ${DIM}# Authorization + auth scaffolding the docs assume:${RST}
  bin/rails generate authentication      ${DIM}# Rails 8 built-in${RST}
  ${DIM}# rubocop / brakeman / bundler-audit are wired for CI (.claude/testing.md)${RST}
  bin/rails server
EOF
else
  cat <<EOF
  ${DIM}# review config/database.yml (uses DATABASE_USER / DATABASE_PASSWORD / DATABASE_HOST)${RST}
  bundle exec rake db:create db:migrate
  bundle exec rspec                            ${DIM}# health + home specs${RST}
  bundle exec rackup -p 4567                   ${DIM}# or: bundle exec puma -C config/puma.rb${RST}
EOF
fi

cat <<EOF

Skill docs live in ${BOLD}$APP_NAME/CLAUDE.md${RST} and ${BOLD}$APP_NAME/.claude/${RST}.
EOF
