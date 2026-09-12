require "test_helper"

# Google issues a refresh_token only on the FIRST consent per user x client.
# The re-auth banner posted with the initializer's prompt=select_account, so a
# user who had consented before offline access was requested got a fresh
# id_token and still no refresh_token — the banner cleared and the same lapse
# returned an hour later, indefinitely. Seen in production 2026-09-12:
# has_refresh_token = false for an account that had signed in many times.
#
# Only the re-auth path forces consent; ordinary sign-in stays frictionless.
class ReauthConsentTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FAMILIES = [
    { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local",
      available_models: [ { "value" => "qwen3-8-27b", "label" => "qwen3.8:27b" } ] } ] }
  ].freeze

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, body: { llms: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def lapsed_user
    User.create!(email: "lapsed@example.com", google_id: "g-lapsed",
                 id_token: "stale", refresh_token: nil,
                 id_token_expires_at: 1.minute.ago)
  end

  def healthy_user
    User.create!(email: "fresh@example.com", google_id: "g-fresh",
                 id_token: "good", id_token_expires_at: 1.hour.from_now)
  end

  test "the re-auth banner asks Google for consent, so a refresh_token is issued" do
    sign_in lapsed_user

    get root_path

    assert_select "div.reauth-banner"
    assert_select "div.reauth-banner input[name=?][value=?]", "prompt", "consent"
  end

  test "a user with a usable token sees no banner at all" do
    sign_in healthy_user

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, FAMILIES) do
      get root_path
    end

    assert_select "div.reauth-banner", false
  end

  test "ordinary sign-in is not forced through the consent screen" do
    get root_path

    # The header's sign-in form must not carry prompt=consent; only the
    # recovery path does, so normal sign-in stays a single click.
    assert_select "input[name=?][value=?]", "prompt", "consent", false
  end
end
