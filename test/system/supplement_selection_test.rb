require "application_system_test_case"

# Browser-level coverage for the parts of aggregation that only exist at
# runtime: the ctrl+click gesture, what the controller shows in response, and
# whether things the controller hides are actually invisible.
#
# These are the only tests that touch this ground. The request tests assert
# markup, which cannot catch a control that is rendered-but-unclickable or —
# as happened once here — an element with `hidden` set that CSS keeps on
# screen anyway, because an author `display: flex` outranks the UA rule.
class SupplementSelectionTest < ApplicationSystemTestCase
  FAMILIES = [
    { llm_type: "ollama", name: "Ollama", api_keys: [ { uuid: "ollama-local", available_models: [
      { "value" => "qwen3-8-27b", "label" => "qwen3.8:27b" }
    ] } ] }
  ].freeze

  setup do
    # Stub at the HTTP boundary rather than stubbing the client class. The
    # server runs in this process but serves the browser from another thread,
    # so a block-scoped Minitest stub would not reliably be in force for the
    # requests the browser makes.
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
    stub_request(:get, "#{base}/api/llm_api_keys")
      .to_return(status: 200, body: { llm_api_keys: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "sys-uid",
      info: { email: "sys@example.com" },
      credentials: { refresh_token: "rt", expires_at: 1.hour.from_now.to_i },
      extra: { id_token: "id-tok" }
    )
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  # The chat has to be owned by the browser's own session, or
  # visible_chats_scope hides it and the page redirects away. Signing in is the
  # reliable way to get there: an anonymous chat is keyed on a token minted
  # inside the browser's session cookie, which the test process cannot read.
  # A public chat would not do either — it renders read-only for a non-owner,
  # so there would be no composer to test.
  def sign_in_through_browser
    visit root_path
    click_button "Sign in with Google"
    # Wait for the redirect to land before querying: click_button returns as
    # soon as the request is issued, so the User row may not exist yet.
    assert_text "sys@example.com"
    User.find_by!(email: "sys@example.com")
  end

  # Built directly rather than through the UI: driving the composer would need
  # a live LLM round-trip, and what is under test here is the selection
  # gesture, not prompt submission.
  def seed_chat
    user = sign_in_through_browser
    chat = Chat.create!(uuid: SecureRandom.uuid, user: user)
    %w[alpha beta gamma].each_with_index do |word, i|
      pe = PromptNavigator::PromptExecution.create!(
        prompt: "question #{word}", response: "answer #{word}", model: "qwen3-8-27b"
      )
      chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
      chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)
    end
    chat
  end

  def card_for(prompt_text)
    find(".history-card", text: prompt_text)
  end

  def ctrl_click(node)
    page.driver.browser.action.key_down(:control).click(node.native).key_up(:control).perform
  end

  test "the presets stay out of sight until something is cited" do
    chat = seed_chat
    visit chat_path(chat.uuid)

    # `hidden` alone is not enough: the bug this guards against was an author
    # `display: flex` overriding it, leaving the buttons permanently on screen.
    assert_no_selector ".supplement-presets", visible: true
    assert_no_selector ".supplement-chips", visible: true

    ctrl_click(card_for("question alpha"))

    assert_selector ".supplement-presets", visible: true
    assert_selector ".supplement-chip", text: "question alpha", visible: true
  end

  test "ctrl+click marks the card and fills the hidden field" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))
    ctrl_click(card_for("question beta"))

    assert_selector ".history-card.is-supplement", count: 2
    cited = chat.ordered_prompt_executions.first(2).map(&:execution_id)
    assert_equal cited.join(","), find("#supplement_uuids", visible: false).value
  end

  test "a plain click navigates instead of selecting" do
    chat = seed_chat
    visit chat_path(chat.uuid)

    card_for("question alpha").find(".history-card-link").click

    assert_no_selector ".history-card.is-supplement"
    assert_equal "", find("#supplement_uuids", visible: false).value
  end

  test "ctrl+clicking a cited card again drops it" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))
    assert_selector ".history-card.is-supplement", count: 1

    ctrl_click(card_for("question alpha"))

    assert_no_selector ".history-card.is-supplement"
    assert_no_selector ".supplement-presets", visible: true
  end

  test "the chip's remove control drops the citation" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))

    find(".supplement-chip-remove").click

    assert_no_selector ".supplement-chip"
    assert_equal "", find("#supplement_uuids", visible: false).value
  end

  test "a preset fills the box and then withdraws" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))

    click_button "Compare"

    assert_match(/referring to each answer by its model name/, find("#message-input").value)
    assert_no_selector ".supplement-presets", visible: true
  end

  test "the Start node cannot be cited" do
    chat = seed_chat
    visit chat_path(chat.uuid)

    ctrl_click(find(".history-card-start"))

    assert_no_selector ".history-card.is-supplement"
    assert_equal "", find("#supplement_uuids", visible: false).value
  end

  # The panel answers "what is actually sent", so it has to show the real
  # assembled block, fetched from the server.
  test "the preview shows the block that would be sent" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))

    assert_no_selector ".supplement-preview", visible: true
    click_button "show what will be sent"

    assert_selector ".supplement-preview", visible: true, text: "Referenced material"
    assert_selector ".supplement-preview", text: "[1] qwen3-8-27b — answer alpha"
  end

  # ----- telling the two highlights apart -----

  def style_of(node, prop)
    page.evaluate_script("getComputedStyle(arguments[0]).#{prop}", node)
  end

  # Clicking leaves the pointer on the card, and the gem gives .history-card a
  # hover shadow that replaces the active ring — so a box-shadow assertion
  # taken straight after a click measures hover, not state. Park the pointer
  # somewhere inert first.
  def move_pointer_away
    page.driver.browser.action.move_to(find("h2.history-heading").native).perform
  end

  # Both states used to be a solid coloured border plus a ring, differing only
  # in hue, so a cited card read as just another active card.
  test "a cited card is dashed while the active card stays solid" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))

    cited  = find(".history-card.is-supplement")
    active = find(".history-card.is-active")

    assert_equal "dashed", style_of(cited, "borderTopStyle")
    assert_equal "solid",  style_of(active, "borderTopStyle")
  end

  # The gem's stylesheet is linked after the app's and its `.is-active` rule
  # carries equal specificity, so without the id prefix the dashed border loses
  # the tie on precisely the card that needs both signals.
  test "a card that is both active and cited keeps both signals" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    active_text = find(".history-card.is-active .history-card-prompt").text
    ctrl_click(card_for(active_text))

    both = find(".history-card.is-active.is-supplement")
    move_pointer_away

    assert_equal "dashed", style_of(both, "borderTopStyle"),
                 "the reference border must survive the active rule"
    assert_includes style_of(both, "boxShadow"), "rgba(0, 123, 255",
                    "the active ring must survive being cited"
  end

  # A plain card must not pick up either treatment.
  test "an uninvolved card carries neither highlight" do
    chat = seed_chat
    visit chat_path(chat.uuid)
    ctrl_click(card_for("question alpha"))

    plain = find(".history-card", text: "question beta")

    assert_equal "solid", style_of(plain, "borderTopStyle")
    assert_no_selector ".history-card.is-supplement", text: "question beta"
  end
end
