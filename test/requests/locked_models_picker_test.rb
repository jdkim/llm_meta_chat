require "test_helper"

# The picker for a visitor with no API keys: commercial providers appear,
# legible and clearly disabled, rather than being absent entirely.
class LockedModelsPickerTest < ActionDispatch::IntegrationTest
  # A signed-out visitor really does get the free Ollama family (it needs no
  # key); stubbing an empty list would skip the picker altogether, since the
  # whole panel is guarded by `@llm_families.present?`.
  def anon_families
    [ { name: "Ollama", llm_type: "ollama",
        api_keys: [ { uuid: "ollama-local", description: "Local Ollama", llm_type: "ollama",
                      available_models: [ { "label" => "qwen3.6:35b", "value" => "qwen3-6-35b" } ] } ] } ]
  end

  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [
                   { "family" => "openai", "name" => "OpenAI", "models" => [
                     { "display_name" => "GPT-5.5 Pro", "active" => true, "supports_vision" => true }
                   ] }
                 ] }.to_json)
  end

  test "an unsigned visitor sees the commercial provider and its model names" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    assert_response :success
    assert_match "GPT", response.body
    # The model name is the pitch — it must be present, not blurred away.
    assert_match "GPT-5.5 Pro", response.body
  end

  test "the instruction appears once, not on every locked card" do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [
                   { "family" => "openai",    "name" => "OpenAI",    "models" => [ { "display_name" => "GPT-5.5 Pro", "active" => true } ] },
                   { "family" => "anthropic", "name" => "Anthropic", "models" => [ { "display_name" => "Claude Opus 5", "active" => true } ] },
                   { "family" => "google",    "name" => "Google",    "models" => [ { "display_name" => "Gemini 3.1 Pro", "active" => true } ] }
                 ] }.to_json)

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    # Three locked providers, one banner.
    assert_equal 3, response.body.scan("model-grid-column is-locked").size
    assert_equal 1, response.body.scan("register your API key to unlock the greyed-out models").size
  end

  test "the locked card explains what to do, without relying on hover" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    # A tooltip never fires on touch, so the instruction is visible text.
    assert_match "register your API key to unlock the greyed-out models", response.body
  end

  test "the free card sits in the bottom-left cell, nearest the button that opens the panel" do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [
                   { "family" => "openai",    "name" => "OpenAI",    "models" => [ { "display_name" => "GPT-5.5 Pro", "active" => true } ] },
                   { "family" => "anthropic", "name" => "Anthropic", "models" => [ { "display_name" => "Claude Opus 5", "active" => true } ] },
                   { "family" => "google",    "name" => "Google",    "models" => [ { "display_name" => "Gemini 3.1 Pro", "active" => true } ] }
                 ] }.to_json)

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    titles = response.body.scan(/model-grid-header">\s*(\w[\w .]*)/).flatten.map(&:strip)

    # Two columns, so the last row starts at index 2 — Free belongs there,
    # closest to the "Other models" button below the panel.
    assert_equal 4, titles.size
    assert_equal "Free", titles[2]
  end

  test "the banner links to the hub, where API keys actually live" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    banner = response.body[/model-grid-locked-banner.*?<\/p>/m].to_s

    # Keys are held by the hub, not this app — signing in here unlocks nothing.
    assert_includes banner, Rails.configuration.llm_service_public_url
    assert_includes banner, "hub.AIbranch"
    assert_includes banner, "Sign in at"
  end

  test "the banner uses a link, never a nested form inside the chat form" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    banner = response.body[/model-grid-locked-banner.*?<\/p>/m].to_s
    assert_not_includes banner, "<form"

    # A <form> nested in the chat form is invalid HTML: browsers drop it and
    # the click submits the chat form, tripping its required-field validation.
    chat_form = response.body[/<form class="chat-form".*?<\/form>/m].to_s
    assert chat_form.present?, "chat form should render"
    assert_not_includes chat_form.sub(/\A<form[^>]*>/, ""), "<form"
  end

  test "the redundant footer message is gone — the banner says it once" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    assert_not_includes response.body, "model-grid-footer"
    assert_not_includes response.body, "to unlock more models by registering your API keys"
  end

  test "locked models are not selectable" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    body = response.body
    locked = body[/model-grid-column is-locked.*?<\/div>\s*<\/div>/m].to_s

    assert_includes locked, "is-disabled"
    assert_includes locked, 'aria-disabled="true"'
    # No click target, so a locked row cannot be picked.
    assert_not_includes locked, "model-picker#pick"
  end

  test "the page still renders when the catalog cannot be reached" do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms").to_return(status: 500)

    with_stub(LlmMetaClient::ServerResource, :available_llm_families, anon_families) do
      get root_path
    end

    assert_response :success
  end

  # Once every provider is keyed there is nothing to unlock, but the hub still
  # holds favorites and the default-model setting — which the old footer
  # mentioned and nothing else does.
  class FullyKeyedTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    setup do
      stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { llms: [] }.to_json)
      @user = User.create!(email: "keyed@example.com", google_id: "g-keyed",
                           id_token: "tok", id_token_expires_at: 1.hour.from_now)
      sign_in @user
    end

    def keyed_families
      [ { name: "OpenAI", llm_type: "openai",
          api_keys: [ { uuid: "k1", description: "mine", llm_type: "openai",
                        available_models: [ { "label" => "GPT-5.5", "value" => "gpt-5-5" } ] } ] } ]
    end

    test "offers the personalisation the hub still holds" do
      with_stub(LlmMetaClient::ServerResource, :available_llm_families, keyed_families) do
        get root_path
      end

      assert_match "Set your favorite models and a personal default", response.body
      assert_match "hub.AIbranch", response.body
    end

    test "does not nag about unlocking when there is nothing locked" do
      with_stub(LlmMetaClient::ServerResource, :available_llm_families, keyed_families) do
        get root_path
      end

      assert_not_includes response.body, "to unlock the greyed-out models"
      assert_not_includes response.body, "model-grid-column is-locked"
    end
  end
end
