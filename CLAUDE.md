# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Rails 8.1 on Ruby 3.4.9 (the README's "Ruby 4.0.1" is incorrect — `.ruby-version` is authoritative). SQLite via `sqlite3`, Solid Queue / Cache / Cable for background infra, Propshaft + importmap + Hotwire (Turbo + Stimulus), Devise + OmniAuth (Google) for auth, Kamal for deploy.

## Commands

- `bin/setup` — install deps, prepare DB, start server (add `--skip-server` to skip)
- `bin/dev` — run the dev server
- `bin/rails test` — unit/integration tests; `bin/rails test:system` for system tests
- `bin/rails test test/models/chat_test.rb:42` — run a single test by file:line
- `bin/rubocop` — lint (rails-omakase)
- `bin/brakeman` — security static analysis
- `bin/bundler-audit` — gem CVE audit
- `bin/ci` — runs the full CI pipeline locally (setup, rubocop, audits, brakeman, tests, system tests, seed replant) — mirrors `.github/workflows/ci.yml`
- `bin/rails credentials:edit` — manage secrets (see README for key layout)

## Architecture

This is a **thin test/demo host** for the `llm_meta_client` Rails engine (external gem, currently `~> 1.0`, resolved to `1.0.2`). Most of the LLM domain logic lives in that gem — this app glues it into a chat UI.

### The llm_meta_client gem (external dependency)

The gem is a Rails Engine and provides modules that are `include`d into this app's controllers/models. Key surfaces used here:

- `LlmMetaClient::ServerResource` — fetches available LLM families / options / keys from the external LLM service
- `LlmMetaClient::ServerQuery` — sends chat requests to the external LLM service
- `ChatManager::ChatManageable`, `ChatManager::CsvDownloadable`, `ChatManager::TitleGeneratable` — mixins that drive sidebar chat listing, CSV export, and LLM-generated titles
- `PromptNavigator::HistoryManageable` — mixin for the per-chat history/branching sidebar
- `PromptNavigator::PromptExecution` — ActiveRecord model owned by the gem (table `prompt_navigator_prompt_executions`) that represents one prompt→response round with a `previous_id` self-reference for branching

When concerns or class names appear unresolved in this repo, they almost certainly live in the gem — look under the installed gem path (e.g. `$(bundle info llm_meta_client --path)`).

### Domain model

`User` → has_many `Chat` → has_many `Message`. Each `Message` belongs to exactly one `PromptNavigator::PromptExecution` (from the gem), which holds the actual `prompt`, `response`, `llm_uuid`, `model`, and a `previous_id` forming a conversation DAG that supports branching.

### Request flow (Chat#create / Chat#update)

1. Controller validates `generation_settings_json` (allowed keys: `temperature`, `top_k`, `top_p`, `max_tokens`, `repeat_penalty`; all must be numeric) — see `ChatsController#generation_settings_param`.
2. `Chat#add_user_message` creates a `PromptExecution` linked to the previous execution (or to `branch_from_uuid` to fork a new branch) plus a user `Message`.
3. `Chat#send_to_llm` calls `LlmMetaClient::ServerQuery` to **first summarize prior context** (bounded by `Rails.configuration.summarize_conversation_count`, default 10), then sends the summarized context + current prompt to the LLM.
4. `Chat#add_assistant_response` stores the reply onto the `PromptExecution` and creates the assistant `Message`.
5. Responses render via Turbo Streams (`create.turbo_stream.erb` / `update.turbo_stream.erb`); HTML fallback redirects.

### Auth

Devise with Google OAuth2 (`users/omniauth_callbacks_controller.rb`). Chats may be created **anonymously** — `user` is `optional: true` on `Chat` and anonymous chats are keyed by `session[:chat_id]` with `user_id: nil`. Only title-edit and CSV download require login (`before_action :authenticate_user!, only: …` in `ChatsController`).

### External configuration

`config.llm_service_base_url` and `config.summarize_conversation_count` are loaded from Rails credentials in `config/initializers/llm_service.rb` and consumed via `Rails.configuration.*`. The external LLM service defaults to `http://localhost:3000`.

### API namespace

`/api/mcp_servers` (index + `tools` member action, keyed by `:uuid`) proxies MCP tool metadata — see `app/controllers/api/mcp_servers_controller.rb`.
