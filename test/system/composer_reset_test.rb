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
    # Signing in navigates without going through `visit`, so settle here too.
    wait_for_turbo
    # Signing in navigates without going through `visit`, so settle here too.
    wait_for_turbo
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
    ctrl_click { find(".history-card", text: "question alpha") }
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
    ctrl_click { find(".history-card", text: "question alpha") }
    fill_in "message-input", with: "something"

    reset_button.click

    assert_selector ".history-card.is-supplement", count: 1
    assert_selector ".supplement-chip", count: 1
  end

  test "it is offered on a brand-new chat too" do
    visit root_path

    assert_selector ".reset-button", visible: :all
  end

  # ----- composer layout -----

  def control_boxes
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll('.input-wrapper button')].map((e) => {
        const b = e.getBoundingClientRect()
        return { name: e.className, left: b.left, right: b.right, top: b.top, bottom: b.bottom }
      })
    JS
  end

  # Every .attach-button used to position itself at the same `right: 56px`, so
  # each icon sat on top of the last — the image and document buttons already
  # overlapped, and adding reset made a three-way pile. Markup assertions see
  # three perfectly good buttons; only geometry sees the problem.
  test "no two composer controls overlap" do
    visit chat_path(seed_chat.uuid)
    fill_in "message-input", with: "draft"

    boxes = control_boxes
    assert_operator boxes.length, :>=, 3, "expected the icon row plus send"

    boxes.combination(2).each do |a, b|
      overlap = a["left"] < b["right"] && b["left"] < a["right"] &&
                a["top"] < b["bottom"] && b["top"] < a["bottom"]
      assert_not overlap, "#{a["name"]} overlaps #{b["name"]}"
    end
  end

  # The textarea reserves its right edge for these controls. Reserve too little
  # and a full line of text runs underneath them, which is how this looked in
  # practice before the row existed.
  test "typed text does not run under the icon row" do
    visit chat_path(seed_chat.uuid)
    fill_in "message-input", with: "draft"

    clearance = page.evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector('.chat-input')
        const row = document.querySelector('.input-actions')
        const reserved = parseFloat(getComputedStyle(input).paddingRight)
        const needed = input.getBoundingClientRect().right - row.getBoundingClientRect().left
        return { reserved: reserved, needed: needed }
      })()
    JS

    assert_operator clearance["reserved"], :>=, clearance["needed"],
                    "the input reserves #{clearance["reserved"]}px but the controls need #{clearance["needed"]}px"
  end
end
