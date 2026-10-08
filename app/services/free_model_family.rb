# frozen_string_literal: true

# The "Free" pseudo-family: models anyone may use without supplying a key,
# gathered from WHATEVER provider they actually belong to.
#
# Free-ness is a property of the model, not of a provider — gpt-oss runs on
# Bedrock and medgemma on the local Ollama, yet both are free to the visitor.
# Grouping them by provider would scatter them across the picker and, worse,
# file a hosted model under "Local Ollama (no API key required)", which quietly
# misstates where the prompt goes.
#
# The synthetic uuid is the mechanism that makes this work for signed-in users
# too: it matches none of their keys, so the hub resolves llm_api_key to nil,
# the free_access gate opens and the server pays with the house key. Exactly
# how "ollama-local" has always behaved.
#
# Fetches /api/llms directly, as LockedModelFamilies does — the client gem
# builds families from the visitor's own keys and has no notion of a model
# that belongs to nobody.
class FreeModelFamily
  UUID      = "free-models"
  FREE_TYPE = "free"
  NAME    = "Free"
  TIMEOUT = 5

  # Returns [] when nothing is free, so callers can concat unconditionally.
  def self.build
    models = fetch.flat_map { |family| free_models_in(family) }
    return [] if models.empty?

    [ { name: NAME, llm_type: FREE_TYPE,
        api_keys: [ { uuid: UUID, description: NAME, llm_type: FREE_TYPE,
                      available_models: models } ] } ]
  end

  # Two shapes come back from /api/llms. Real families carry `models` (the
  # LlmModel#as_json shape, name/display_name). The Ollama entry is synthetic
  # and carries `available_models` (the picker shape, value/label) — so
  # reading only one of them silently loses half the free models, which is
  # exactly what happened to medgemma the first time.
  def self.free_models_in(family)
    rows = Array(family["models"]).presence || Array(family["available_models"])
    rows.filter_map do |m|
      next unless m["free_access"] == true && m["active"] != false

      { "label" => (m["display_name"].presence || m["label"].presence || m["name"] || m["value"]),
        "value" => (m["name"] || m["value"]),
        "supports_vision" => m["supports_vision"] == true,
        "supports_tools"  => m["supports_tools"] == true,
        "kind"            => m["kind"].presence }
    end
  end

  def self.fetch
    resp = HTTParty.get("#{Rails.configuration.llm_service_base_url}/api/llms",
                        headers: { "Content-Type" => "application/json" }, timeout: TIMEOUT)
    return [] unless resp.success?

    resp.parsed_response["llms"] || []
  rescue StandardError => e
    # Losing the free models is bad; failing the whole page is worse.
    Rails.logger.warn "[FreeModelFamily] #{e.class}: #{e.message}"
    []
  end

  # True for the pseudo-family, and still for a bare ollama family so the
  # picker keeps rendering correctly during the transition.
  def self.free?(llm_type)
    [ FREE_TYPE, "ollama" ].include?(llm_type.to_s)
  end
end
