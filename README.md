# LLM Meta Test Service

A Rails application for meta-management of LLM services.

## Requirements

- Ruby 3.4.9 (see `.ruby-version`)
- Rails 8.1.2

## Setup

```bash
bundle install
rails db:create db:migrate
```

## Credentials

This application uses Rails credentials to manage secrets.

### Editing

```bash
rails credentials:edit
```

### Key Structure

```yaml
google:
  client_id: <Google OAuth 2.0 client ID>
  client_secret: <Google OAuth 2.0 client secret>

llm_service:
  base_url: <LLM service base URL (default: http://localhost:3000)>
  summarize_conversation_count: <Conversation summarization threshold (default: 10)>
```

### Reference

| Key | Purpose | Default |
|-----|---------|---------|
| `google.client_id` | Google Sign-In (Devise OmniAuth) | None (required) |
| `google.client_secret` | Google Sign-In (Devise OmniAuth) | None (required) |
| `llm_service.base_url` | External LLM service API base URL | `http://localhost:3000` |
| `llm_service.summarize_conversation_count` | Conversation count threshold for summarization | `10` |

## Testing

```bash
rails test
```
