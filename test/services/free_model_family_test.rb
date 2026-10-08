require "test_helper"

# The "Free" pseudo-family gathers models anyone may use without a key, from
# whatever provider hosts them.
class FreeModelFamilyTest < ActiveSupport::TestCase
  def stub_llms(payload)
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: payload }.to_json)
  end

  # Real families carry `models`; the synthetic Ollama entry carries
  # `available_models`. Reading only one shape lost medgemma entirely.
  test "collects free models from BOTH payload shapes" do
    stub_llms([
      { "family" => "bedrock",
        "models" => [ { "name" => "gpt-oss-120b", "display_name" => "gpt-oss", "free_access" => true,
                        "active" => true, "supports_tools" => true },
                      { "name" => "paid-one", "free_access" => false, "active" => true } ] },
      { "family" => "ollama",
        "available_models" => [ { "value" => "medgemma1-5-4b", "label" => "medgemma", "free_access" => true } ] }
    ])

    models = FreeModelFamily.build.first[:api_keys].first[:available_models]

    assert_equal %w[gpt-oss-120b medgemma1-5-4b], models.map { |m| m["value"] }.sort
  end

  test "excludes models that are not flagged free" do
    stub_llms([ { "family" => "bedrock",
                  "models" => [ { "name" => "paid-one", "free_access" => false, "active" => true } ] } ])
    assert_empty FreeModelFamily.build
  end

  test "excludes inactive models even when flagged" do
    stub_llms([ { "family" => "bedrock",
                  "models" => [ { "name" => "hidden", "free_access" => true, "active" => false } ] } ])
    assert_empty FreeModelFamily.build
  end

  # The synthetic uuid is what makes a signed-in user fall through to the
  # house key: it matches none of their own keys.
  test "uses a synthetic uuid that is not a real key" do
    stub_llms([ { "family" => "bedrock",
                  "models" => [ { "name" => "gpt-oss-120b", "free_access" => true, "active" => true } ] } ])
    assert_equal "free-models", FreeModelFamily.build.first[:api_keys].first[:uuid]
  end

  # Losing the free models is bad; failing the page render is worse.
  test "returns empty rather than raising when the hub is unreachable" do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms").to_timeout
    assert_empty FreeModelFamily.build
  end
end
