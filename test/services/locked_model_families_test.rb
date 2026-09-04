require "test_helper"

# A signed-out visitor's picker is built from their own API keys, so it shows
# only the free local models — with no sign that GPT, Claude or Gemini exist.
# These provider cards are the reason to sign in.
class LockedModelFamiliesTest < ActiveSupport::TestCase
  def stub_llms(payload)
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: payload }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def catalog
    [
      { "family" => "ollama", "name" => "Ollama", "models" => [ { "display_name" => "qwen", "active" => true } ] },
      { "family" => "openai", "name" => "OpenAI",
        "models" => [ { "display_name" => "GPT-5.5", "active" => true, "supports_tools" => true } ] },
      { "family" => "anthropic", "name" => "Anthropic",
        "models" => [ { "display_name" => "Claude Opus 5", "active" => true } ] }
    ]
  end

  test "lists commercial providers the visitor has no key for" do
    stub_llms(catalog)

    families = LockedModelFamilies.for(unlocked_types: [])

    assert_equal %w[GPT Claude], families.map { it[:title] }
  end

  test "never lists ollama — it needs no key" do
    stub_llms(catalog)

    assert_not_includes LockedModelFamilies.for(unlocked_types: []).map { it[:llm_type] }, "ollama"
  end

  test "omits a provider the visitor already has a key for" do
    stub_llms(catalog)

    families = LockedModelFamilies.for(unlocked_types: [ "openai" ])

    assert_equal [ "anthropic" ], families.map { it[:llm_type] }
  end

  test "carries the model names, which are the reason to sign in" do
    stub_llms(catalog)

    openai = LockedModelFamilies.for(unlocked_types: []).first

    assert_equal [ "GPT-5.5" ], openai[:models].map { it["display_name"] }
  end

  test "skips a provider whose models are all inactive" do
    stub_llms([ { "family" => "openai", "name" => "OpenAI",
                  "models" => [ { "display_name" => "Retired", "active" => false } ] } ])

    assert_empty LockedModelFamilies.for(unlocked_types: [])
  end

  test "returns empty rather than failing the page when the catalog is unreachable" do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms").to_return(status: 500)

    assert_empty LockedModelFamilies.for(unlocked_types: [])
  end
end
