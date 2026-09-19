require "application_system_test_case"

# The help bubble on the history pane heading.
#
# Asserted through computed style rather than the presence of markup: a
# tooltip that is in the DOM but painted on screen at all times, or one that
# never appears on hover, both render perfectly in an HTML assertion. That
# exact failure — an author `display:` rule outranking the UA `[hidden]` rule —
# has already shipped once from this pane.
class HistoryHelpTest < ApplicationSystemTestCase
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
      provider: "google_oauth2", uid: "help-uid",
      info: { email: "help@example.com" },
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
    assert_text "help@example.com"
    user = User.find_by!(email: "help@example.com")

    chat = Chat.create!(uuid: SecureRandom.uuid, user: user)
    pe = PromptNavigator::PromptExecution.create!(
      prompt: "question alpha", response: "answer alpha", model: "qwen3-8-27b"
    )
    chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
    chat
  end

  def bubble_style(prop)
    page.evaluate_script(
      "getComputedStyle(document.getElementById('history-help-bubble')).#{prop}"
    )
  end

  # The bubble transitions over 0.12s, so reading computed style the instant
  # after focusing or hovering can catch it mid-flight. Poll the way Capybara
  # polls for everything else rather than sleeping a guessed amount.
  def assert_bubble(prop, expected)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    actual = nil
    loop do
      actual = bubble_style(prop)
      break if actual == expected
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert_equal expected, actual, "help bubble #{prop}"
  end

  test "the help mark sits beside the History heading" do
    visit chat_path(seed_chat.uuid)

    assert_selector "h2.history-heading", text: "History"
    assert_selector "h2.history-heading .history-help", text: "?"
  end

  test "the bubble is not painted until asked for" do
    visit chat_path(seed_chat.uuid)

    assert_bubble "visibility", "hidden"
    assert_bubble "opacity", "0"
  end

  test "hovering the mark reveals the bubble" do
    visit chat_path(seed_chat.uuid)

    find(".history-help").hover

    assert_bubble "visibility", "visible"
    assert_bubble "opacity", "1"
  end

  test "the bubble names all three gestures" do
    visit chat_path(seed_chat.uuid)
    find(".history-help").hover

    bubble = find("#history-help-bubble", visible: :all)
    assert_match(/revisit that prompt/, bubble.text(:all))
    assert_match(/branches/i, bubble.text(:all))
    assert_match(/Ctrl-click/i, bubble.text(:all))
    assert_match(/reference/i, bubble.text(:all))
  end

  # Keyboard users have no hover. The mark is focusable for that reason, so
  # the rule has to fire on focus too.
  test "focusing the mark reveals the bubble" do
    visit chat_path(seed_chat.uuid)

    page.execute_script("document.querySelector('.history-help').focus()")

    assert_bubble "visibility", "visible"
  end

  # .sidebar sets overflow-y, which makes the x-axis clip as well, so a bubble
  # wider than the pane is cut off rather than overflowing it.
  test "the bubble stays inside the pane" do
    visit chat_path(seed_chat.uuid)
    find(".history-help").hover

    fits = page.evaluate_script(<<~JS)
      (() => {
        const b = document.getElementById('history-help-bubble').getBoundingClientRect()
        const pane = document.getElementById('history-sidebar').getBoundingClientRect()
        return b.left >= pane.left - 1 && b.right <= pane.right + 1
      })()
    JS
    assert fits, "the help bubble must not overflow the history pane"
  end
end
