require "application_system_test_case"

# The reset control on the prompt box.
#
# Driven in a browser because every part of it is runtime behaviour: whether
# the button is inert, what it actually empties, and — the reason it exists —
# whether the preset buttons come back afterwards, which happens off an input
# event rather than anything server-rendered.
class ComposerResetTest < ApplicationSystemTestCase
  setup do
    base = Rails.configuration.llm_service_base_url
    stub_request(:get, "#{base}/api/llms")
      .to_return(status: 200,
                 body: { llms: [ { "family" => "ollama", "uuid" => "ollama-local",
                                   "description" => "Ollama", "llm_type" => "ollama",
                                   "available_models" => [ { "value" => "qwen3-8-27b",
                                                             "label" => "qwen3.8:27b" } ] } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base}/api/llm_api_keys")
      .to_return(status: 200, body: { llm_api_keys: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "reset-uid",
      info: { email: "reset@example.com" },
      credentials: { refresh_token: "rt", expires_at: 1.hour.from_now.to_i },
      extra: { id_token: "id-tok" }
    )
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  def seed_chat
    visit root_path
    click_button "Sign in with Google"
    assert_text "reset@example.com"
    user = User.find_by!(email: "reset@example.com")

    chat = Chat.create!(uuid: SecureRandom.uuid, user: user)
    %w[alpha beta].each do |word|
      pe = PromptNavigator::PromptExecution.create!(
        prompt: "question #{word}", response: "answer #{word}", model: "qwen3-8-27b"
      )
      chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
    end
    chat
  end

  def reset_button = find(".reset-button", visible: :all)

  def ctrl_click(node)
    page.driver.browser.action.key_down(:control).click(node.native).key_up(:control).perform
  end

  test "it is inert while the box is empty" do
    visit chat_path(seed_chat.uuid)

    assert reset_button.disabled?, "nothing staged, nothing to discard"
  end

  test "typing arms it" do
    visit chat_path(seed_chat.uuid)

    fill_in "message-input", with: "a draft"

    assert_not reset_button.disabled?
  end

  test "it empties the box and goes inert again" do
    visit chat_path(seed_chat.uuid)
    fill_in "message-input", with: "a draft I do not want"

    reset_button.click

    assert_equal "", find("#message-input").value
    assert reset_button.disabled?
  end

  # The reason it exists: presets only show while the box is empty, so once one
  # is applied there was no way back to the others without hand-clearing.
  test "clearing an applied preset brings the presets back" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(find(".history-card", text: "question alpha"))
    click_button "Fair comparison"

    assert_no_selector ".supplement-presets", visible: true
    assert_not find("#message-input").value.empty?

    reset_button.click

    assert_selector ".supplement-presets", visible: true
    assert_equal "", find("#message-input").value
  end

  # Citations are a separate choice from the message, and keeping them is what
  # makes the flow above work at all.
  test "it leaves the reference selection alone" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(find(".history-card", text: "question alpha"))
    fill_in "message-input", with: "something"

    reset_button.click

    assert_selector ".history-card.is-supplement", count: 1
    assert_selector ".supplement-chip", count: 1
  end

  test "it is offered on a brand-new chat too" do
    visit root_path

    assert_selector ".reset-button", visible: :all
  end
end
