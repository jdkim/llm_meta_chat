require "test_helper"

# The picker must render EVERY family the hub returns, not just the ones it has
# a brand name for.
#
# Reported symptom: after adding a Bedrock key, signed-out visitors saw a
# Bedrock card (disabled) while signed-in ones saw nothing. The hub was sending
# the family correctly in both cases; _model_grid built its column list from a
# hardcoded [ollama, anthropic, google, openai] lookup and `.compact` silently
# dropped the rest. LockedModelFamilies, which drives the signed-out card,
# already fell back to the server-provided name — hence the inversion.
class ModelGridUnknownFamilyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [] }.to_json)
    @user = User.create!(email: "grid@example.com", google_id: "g-grid",
                         id_token: "tok", id_token_expires_at: 1.hour.from_now)
    sign_in @user
  end

  # A family with no entry in brand_names — exactly Bedrock's situation.
  def families_including_unknown
    [
      { name: "OpenAI", llm_type: "openai",
        api_keys: [ { uuid: "k-openai", description: "mine", llm_type: "openai",
                      available_models: [ { "label" => "GPT-5.5", "value" => "gpt-5-5" } ] } ] },
      { name: "Bedrock", llm_type: "bedrock",
        api_keys: [ { uuid: "k-bedrock", description: "mine", llm_type: "bedrock",
                      available_models: [ { "label" => "gpt-oss-120b (Bedrock Tokyo)",
                                            "value" => "gpt-oss-120b" } ] } ] }
    ]
  end

  test "renders a family that has no hardcoded brand name" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, families_including_unknown) do
      get root_path
    end

    assert_response :success
    assert_includes response.body, "gpt-oss-120b",
                    "the unknown family's models must appear in the picker"
    assert_includes response.body, "k-bedrock",
                    "its api_key uuid must be selectable, not just its label"
  end

  test "still renders the curated families alongside it" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, families_including_unknown) do
      get root_path
    end

    assert_includes response.body, "gpt-5-5", "adding a fallback must not drop the curated ones"
  end

  test "titles the unknown family from the name the hub supplied" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, families_including_unknown) do
      get root_path
    end

    assert_includes response.body, "Bedrock"
  end
end
