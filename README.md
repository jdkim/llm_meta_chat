# LLM Meta Chat

A Rails chat application that runs on top of the LLM Meta infrastructure. It embeds the [`llm_meta_client`](https://github.com/jdkim/llm_meta_client) Rails Engine and talks over REST to a running [`llm_meta_server`](https://github.com/jdkim/llm_meta_server), which in turn fans out to OpenAI, Anthropic, Google, or a local Ollama.

```
┌─────────────────┐    REST + Google ID token    ┌──────────────────┐    Provider SDKs    ┌────────────────────────┐
│  llm_meta_chat  │ ───────────────────────────▶ │  llm_meta_server │ ──────────────────▶ │  OpenAI / Anthropic /  │
│  (this app)     │                              │                  │                     │  Google / Ollama       │
└─────────────────┘                              └──────────────────┘                     └────────────────────────┘
```

This app never talks to a provider API directly — it always goes through `llm_meta_server`.

## System Requirements

- Ruby 3.4.9 (see `.ruby-version`)
- Rails 8.1.2
- PostgreSQL
- Node.js (for asset compilation)
- **A running instance of [`llm_meta_server`](https://github.com/jdkim/llm_meta_server)** — this app cannot function without a reachable backend. Set it up first.

## Installation Steps

1. **Clone the repository**

   ```bash
   git clone https://github.com/jdkim/llm_meta_chat.git
   cd llm_meta_chat
   ```

2. **Install dependencies**

   ```bash
   bundle install
   ```

3. **Configure Rails credentials**

   This app uses Rails credentials (not environment variables) for secrets:

   ```bash
   EDITOR="vim" bin/rails credentials:edit
   ```

   Add the following keys:

   ```yaml
   google:
     client_id: <Google OAuth 2.0 client ID>
     client_secret: <Google OAuth 2.0 client secret>

   llm_service:
     base_url: http://localhost:3000        # URL of your running llm_meta_server
     summarize_conversation_count: 10        # optional; default 10
   ```

   | Key | Purpose | Default |
   |---|---|---|
   | `google.client_id` | Google Sign-In for user auth (Devise + OmniAuth) | Required |
   | `google.client_secret` | Google Sign-In for user auth | Required |
   | `llm_service.base_url` | Base URL of your `llm_meta_server` instance | `http://localhost:3000` |
   | `llm_service.summarize_conversation_count` | How many recent turns to include when summarizing context | `10` |

   **Google OAuth 2.0 setup.** If you don't already have OAuth credentials, follow steps 1–5 of [the server's Google OAuth setup guide](https://github.com/jdkim/llm_meta_server#google-oauth2-setup-instructions), then add the following authorized redirect URIs to the *same* OAuth client:

   ```
   http://localhost:3001/users/auth/google_oauth2/callback     # dev
   https://<your-chat-host>/users/auth/google_oauth2/callback  # production
   ```

   In addition, this app's `google.client_id` must appear in the server's `ALLOWED_GOOGLE_CLIENT_IDS` env var so the server accepts API requests carrying tokens issued to this client.

4. **Set up the database**

   ```bash
   bin/rails db:setup
   ```

   Creates the database, runs migrations, and loads any seed data. Requires a running PostgreSQL server; connection details are configured in `config/database.yml`.

5. **Start the application**

   The Rails default port is 3000, but `llm_meta_server` also runs on 3000. Start this app on a different port — 3001 is used throughout the docs above:

   ```bash
   bin/rails server -p 3001
   # or, for the plain wrapper:
   PORT=3001 bin/dev
   ```

   The chat UI is now available at [http://localhost:3001](http://localhost:3001).

## Verifying Installation

1. **Backend reachable.** With `llm_meta_server` running on port 3000:

   ```bash
   curl -sI http://localhost:3000/up
   # → HTTP/1.1 200 OK
   ```

2. **Chat app reachable.** Open [http://localhost:3001](http://localhost:3001) — the chat UI should render with an LLM selector in the header.

3. **Anonymous Ollama chat** (no Google Sign-In required, assumes an Ollama model is registered on the backend). Select "Ollama Local" in the LLM selector, type a short prompt, and send. A response should stream back.

4. **Signed-in chat.** Click "Sign in with Google". After the OAuth round-trip you should land on the chat page as a signed-in user; any API key you have registered on `llm_meta_server` will appear in the selector.

If step 2 fails, run `RAILS_LOG_LEVEL=debug bin/rails server -p 3001` and re-check. If step 3 fails but the UI loads, the `llm_service.base_url` credential is likely wrong, or the backend has no Ollama model registered.

## Testing

```bash
bin/rails test              # unit + integration
bin/rails test:system       # system tests (browser)
bin/ci                      # full CI pipeline: rubocop, audits, brakeman, tests, system tests
```

## Citation

If you use this software in your research, please cite:

> Kim, J.-D. (2026). *AIbranch: A platform for branched multi-model LLM conversations*. *SoftwareX*. <https://doi.org/10.1016/j.softx.2026.102983>

## Related repositories

- [`llm_meta_server`](https://github.com/jdkim/llm_meta_server) — the backend that this app talks to (install this first)
- [`llm_meta_client`](https://github.com/jdkim/llm_meta_client) — the Rails Engine gem that provides the chat scaffold used here
