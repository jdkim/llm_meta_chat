# frozen_string_literal: true

# Providers the current visitor cannot use yet, with the models they would
# unlock.
#
# The picker is built from the visitor's own API keys, so a signed-out visitor
# sees only the free local models and no indication that GPT, Claude or Gemini
# are available at all. Showing those provider cards — legible but disabled —
# turns the picker into a reason to sign in. Deliberately not blurred: the
# model names are the reason to sign up, a tooltip never fires on touch, and
# blurred text still reaches a screen reader.
#
# Fetches /api/llms directly. LlmMetaClient::ServerResource makes the same
# call, but its `llms` reader is private and only the visitor's own keys come
# back through the public API; this can move into the gem when it grows a
# public catalog reader.
class LockedModelFamilies
  DISPLAY_NAMES = { "openai" => "GPT", "anthropic" => "Claude", "google" => "Gemini" }.freeze
  TIMEOUT = 5

  # @param unlocked_types [Array<String>] llm_types the visitor already has a key for
  def self.for(unlocked_types: [])
    unlocked = Array(unlocked_types).map(&:to_s)

    fetch.filter_map do |family|
      type = family["family"].to_s
      next if type == "ollama" || unlocked.include?(type)

      models = Array(family["models"]).select { |m| m["active"] != false }
      next if models.empty?

      { title: DISPLAY_NAMES.fetch(type, family["name"].to_s), llm_type: type, models: models }
    end
  end

  def self.fetch
    resp = HTTParty.get("#{Rails.configuration.llm_service_base_url}/api/llms",
                        headers: { "Content-Type" => "application/json" }, timeout: TIMEOUT)
    return [] unless resp.success?

    resp.parsed_response["llms"] || []
  rescue StandardError => e
    # A teaser is never worth failing a page render for.
    Rails.logger.warn "[LockedModelFamilies] #{e.class}: #{e.message}"
    []
  end
end
