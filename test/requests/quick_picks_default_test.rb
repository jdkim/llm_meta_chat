require "test_helper"

# The model pre-selected in the composer.
#
# Rails.configuration.default_model is a meta_id matched against every
# (family x api_key x model) option the hub returns; a default the user set
# on the meta-server outranks it. Neither path had a test, and the config
# comment records why that mattered: when the configured default named a
# retired model, the composer silently offered no pre-selected model and
# nothing warned.
class QuickPicksDefaultTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [] }.to_json)
    @user = User.create!(email: "qp@example.com", google_id: "g-qp",
                         id_token: "tok", id_token_expires_at: 1.hour.from_now)
    sign_in @user
  end

  # Shaped like the Free pseudo-family, which is where gpt-oss-120b reaches a
  # visitor with no API key of their own.
  def free_family(user_default: nil)
    [ { name: "Free", llm_type: "free",
        api_keys: [ { uuid: "free-models", description: "Free", llm_type: "free",
                      available_models: [
                        { "label" => "gpt-oss-120b", "value" => "gpt-oss-120b",
                          "default" => user_default == "gpt-oss-120b" },
                        { "label" => "medgemma1.5:4b", "value" => "medgemma1-5-4b",
                          "default" => user_default == "medgemma1-5-4b" }
                      ] } ] } ]
  end

  test "the system-wide default is gpt-oss-120b" do
    assert_equal "gpt-oss-120b", Rails.configuration.default_model
  end

  test "pre-selects the system-wide default when the user has set none" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, free_family) do
      get root_path
    end

    button = css_select(".quick-pick-button.is-default").first
    assert button, "no default quick-pick was rendered"
    assert_equal Rails.configuration.default_model, button["data-model"]
    # It must carry the key that can actually serve it, not just the meta_id.
    assert_equal "free-models", button["data-api-key-uuid"]
  end

  test "a default the user chose outranks the system-wide one" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families,
              free_family(user_default: "medgemma1-5-4b")) do
      get root_path
    end

    button = css_select(".quick-pick-button.is-default").first
    assert_equal "medgemma1-5-4b", button["data-model"]
  end

  test "renders no default button when the configured default is absent from the catalog" do
    absent = [ { name: "Free", llm_type: "free",
                 api_keys: [ { uuid: "free-models", description: "Free", llm_type: "free",
                               available_models: [ { "label" => "other", "value" => "not-the-default" } ] } ] } ]

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, absent) do
      get root_path
    end

    assert_empty css_select(".quick-pick-button.is-default"),
                 "a default naming a model the catalog does not serve must not be invented"
  end
end
