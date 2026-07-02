require "test_helper"

# Tests for the Chat model — the consumer-side domain logic that wires
# user messages through to the meta-server. Two real bugs sat on this
# code path:
#
#   1. "Undefined Image" titles when raw image markdown was handed to the
#      summarizer (fixed in summarize_for_title by extract_attached_image).
#   2. Image bytes lost on chat reload (fixed by prefixing the data-URI
#      markdown into the persisted prompt in add_user_message).
#
# The tests below pin those plus the conversation-context summarization
# decisions in build_streaming_context, since that's where token budget
# regressions silently cost money on every chat.
class ChatTest < ActiveSupport::TestCase
  setup do
    @chat = Chat.create!
  end

  # ----- set_uuid + basic AR ----- #

  test "before_create assigns a UUID to the chat" do
    chat = Chat.create!
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, chat.uuid)
  end

  # ----- add_user_message ----- #

  test "add_user_message creates a PromptExecution + user Message, returning both" do
    pe, msg = @chat.add_user_message("hello", "key-1", "gpt-5", nil, llm_platform: "openai")

    assert pe.persisted?
    assert msg.persisted?
    assert_equal "hello", pe.prompt
    assert_equal "user", msg.role
    assert_equal pe.id, msg.prompt_navigator_prompt_execution_id
    assert_equal "key-1", pe.llm_uuid
    assert_equal "gpt-5", pe.model
    assert_equal "openai", pe.llm_platform
  end

  test "add_user_message links to the previous user message's prompt_execution" do
    pe1, _msg1 = @chat.add_user_message("first", "key-1", "gpt-5")
    pe2, _msg2 = @chat.add_user_message("second", "key-1", "gpt-5")

    assert_equal pe1.id, pe2.previous_id,
      "the second turn must chain off the first user turn's PE"
  end

  test "add_user_message branches off the explicit branch_from_execution_id when given" do
    pe1, _msg1 = @chat.add_user_message("first", "key-1", "gpt-5")
    _pe2, _msg2 = @chat.add_user_message("second", "key-1", "gpt-5")
    pe3, _msg3 = @chat.add_user_message("branch", "key-1", "gpt-5", pe1.execution_id)

    # pe3 forks off pe1, NOT pe2.
    assert_equal pe1.id, pe3.previous_id
  end

  test "add_user_message prepends the attached image as data-URI markdown so it survives reload" do
    pe, _msg = @chat.add_user_message("describe it", "key-1", "gpt-5", nil,
                                       image: { mime: "image/png", data_b64: "AAA" })

    assert_match(/\A!\[\]\(data:image\/png;base64,AAA\)/, pe.prompt)
    assert_includes pe.prompt, "describe it"
  end

  # ----- ordered_messages + ordered_prompt_executions ----- #

  test "ordered_messages returns messages in created_at ascending order" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    pe2, m2 = @chat.add_user_message("second", "k", "gpt-5")

    ordered = @chat.ordered_messages.to_a
    assert_equal [ m1.id, m2.id ], ordered.map(&:id)
  end

  test "ordered_prompt_executions returns only user-role PEs, oldest first" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    # Manually add an assistant message — shouldn't appear in this list.
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2, _m2 = @chat.add_user_message("second", "k", "gpt-5")

    pes = @chat.ordered_prompt_executions
    assert_equal [ pe1.id, pe2.id ], pes.map(&:id)
  end

  # ----- extract_attached_image (private) ----- #

  test "extract_attached_image pulls a leading image into a structured hash" do
    text, image = @chat.send(:extract_attached_image,
                              "![](data:image/png;base64,XYZ)what is this?")
    assert_equal "what is this?", text
    assert_equal({ mime: "image/png", data_b64: "XYZ" }, image)
  end

  test "extract_attached_image returns [original, nil] when no leading image" do
    text, image = @chat.send(:extract_attached_image, "no image here")
    assert_equal "no image here", text
    assert_nil image
  end

  test "extract_attached_image does NOT match an image in the middle of the prompt" do
    text, image = @chat.send(:extract_attached_image,
                              "prefix ![](data:image/png;base64,X)")
    assert_equal "prefix ![](data:image/png;base64,X)", text
    assert_nil image
  end

  test "extract_attached_image consumes whitespace/newlines between image and text" do
    text, _image = @chat.send(:extract_attached_image,
                               "![](data:image/png;base64,X)\n\ndescribe")
    assert_equal "describe", text
  end

  # ----- image_model? (private) ----- #

  test "image_model? is true for meta_ids containing 'image'" do
    assert @chat.send(:image_model?, "gemini-3-pro-image")
    assert @chat.send(:image_model?, "gemini-2-5-flash-image")
  end

  test "image_model? is false for non-image meta_ids" do
    refute @chat.send(:image_model?, "gpt-5")
    refute @chat.send(:image_model?, "claude-opus-4-7")
  end

  # ----- format_transcript (private) ----- #

  test "format_transcript renders each turn as 'User: ...\\nAssistant: ...' separated by blank lines" do
    out = @chat.send(:format_transcript, [
      { prompt: "p1", response: "r1" },
      { prompt: "p2", response: "r2" }
    ])
    assert_equal "User: p1\nAssistant: r1\n\nUser: p2\nAssistant: r2", out
  end

  test "format_transcript returns empty string for an empty turn list" do
    assert_equal "", @chat.send(:format_transcript, [])
  end

  test "format_transcript replaces inline data-URI image markdown with [image] placeholder" do
    out = @chat.send(:format_transcript, [
      { prompt: "![](data:image/png;base64,AAAA) what is this?", response: "An apple." }
    ])
    assert_equal "User: [image] what is this?\nAssistant: An apple.", out
  end

  test "strip_inline_images_in_turn rewrites both prompt and response" do
    stripped = @chat.send(:strip_inline_images_in_turn,
      { prompt: "![](data:image/png;base64,AA) text", response: "look at ![](data:image/jpeg;base64,BB)" }
    )
    assert_equal "[image] text", stripped[:prompt]
    assert_equal "look at [image]", stripped[:response]
  end

  # ----- collect_recent_images (private) ----- #

  test "collect_recent_images returns chronological list capped at HISTORICAL_IMAGE_LIMIT + current" do
    # Build a 4-turn lineage: image, no-image, image, image — then call from
    # a hypothetical "next" PE that points to the most recent turn.
    pe1, _ = @chat.add_user_message("![](data:image/png;base64,IMG1) q1", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2, _ = @chat.add_user_message("q2 no image", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe2)
    pe3, _ = @chat.add_user_message("![](data:image/png;base64,IMG3) q3", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe3)
    pe4, _ = @chat.add_user_message("![](data:image/png;base64,IMG4) q4", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe4)

    # Stand on a future "current" turn whose previous is pe4. Cap = 2, so we
    # take pe4 + pe3 from history (IMG3, IMG4 chronologically) and append the
    # current image last.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "current", previous: pe4)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    assert_equal 3, result.size
    assert_equal [ "IMG3", "IMG4", "CUR" ], result.map { |i| i[:data_b64] }
  end

  test "collect_recent_images returns just the current image when history has none" do
    pe, _ = @chat.add_user_message("hi", "key", "gpt-5")
    next_pe = PromptNavigator::PromptExecution.new(prompt: "next", previous: pe)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })
    assert_equal [ "CUR" ], result.map { |i| i[:data_b64] }
  end

  test "collect_recent_images returns empty list when no images anywhere" do
    pe, _ = @chat.add_user_message("hi", "key", "gpt-5")
    next_pe = PromptNavigator::PromptExecution.new(prompt: "next", previous: pe)
    assert_empty @chat.send(:collect_recent_images, next_pe, current_image: nil)
  end

  test "collect_recent_images follows the branch chain, not the chat's global chronology" do
    # Trunk: text-only → image — chronologically present in the chat but
    # NOT on the branch we'll send from.
    trunk_a, _ = @chat.add_user_message("trunk text", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)
    trunk_b, _ = @chat.add_user_message("![](data:image/png;base64,TRUNK) trunk picture", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_b)

    # Branch off trunk_a (the FIRST trunk PE), with one image.
    branch, _ = @chat.add_user_message(
      "![](data:image/png;base64,BRANCH) branch picture",
      "key", "gpt-5",
      trunk_a.execution_id
    )
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: branch)

    # New prompt sent from the branch tip — its `previous` is `branch`.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "follow-up on branch", previous: branch)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    # Should pick up only the branch's image + current. trunk_b's image is on
    # a different branch and must not leak in.
    data = result.map { |i| i[:data_b64] }
    assert_equal [ "BRANCH", "CUR" ], data
    refute_includes data, "TRUNK"
  end

  test "collect_recent_images caps at HISTORICAL_IMAGE_LIMIT on a branched lineage (most recent wins)" do
    # Off-branch trunk image — must be invisible.
    trunk_a, _ = @chat.add_user_message("![](data:image/png;base64,TRUNK) trunk", "key", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)

    # Build a branch off trunk_a with four image-bearing PEs in a row:
    # R (oldest on branch) → X → Y → Z (newest on branch).
    img_r, _ = @chat.add_user_message("![](data:image/png;base64,IMG_R) r", "key", "gpt-5", trunk_a.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_r)
    img_x, _ = @chat.add_user_message("![](data:image/png;base64,IMG_X) x", "key", "gpt-5", img_r.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_x)
    img_y, _ = @chat.add_user_message("![](data:image/png;base64,IMG_Y) y", "key", "gpt-5", img_x.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_y)
    img_z, _ = @chat.add_user_message("![](data:image/png;base64,IMG_Z) z", "key", "gpt-5", img_y.execution_id)
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: img_z)

    # New PE sent from img_z — walks back along its branch chain.
    next_pe = PromptNavigator::PromptExecution.new(prompt: "now", previous: img_z)
    result = @chat.send(:collect_recent_images, next_pe,
                        current_image: { mime: "image/png", data_b64: "CUR" })

    # HISTORICAL_IMAGE_LIMIT = 2 — keep the two CLOSEST to current (Y and Z),
    # not the oldest two (R and X). Trunk's image must not leak in.
    data = result.map { |i| i[:data_b64] }
    assert_equal [ "IMG_Y", "IMG_Z", "CUR" ], data
    refute_includes data, "IMG_R"
    refute_includes data, "IMG_X"
    refute_includes data, "TRUNK"
  end

  # ----- build_streaming_context branch awareness ----- #

  test "build_streaming_context formats only the branch's lineage, not sibling-branch turns" do
    # Trunk-A → Trunk-B (sibling branch off Trunk-A), and Trunk-A → Branch-C
    # (the branch we'll send from).
    trunk_a, _ = @chat.add_user_message("trunk-a question", "key", "gpt-5")
    trunk_a.update!(response: "trunk-a answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_a)

    trunk_b, _ = @chat.add_user_message("trunk-b sibling talk", "key", "gpt-5", trunk_a.execution_id)
    trunk_b.update!(response: "trunk-b answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: trunk_b)

    branch_c, _ = @chat.add_user_message("branch-c follow-up", "key", "gpt-5", trunk_a.execution_id)
    branch_c.update!(response: "branch-c answer")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: branch_c)

    # New prompt sent from the branch tip (branch_c). build_streaming_context
    # should anchor on this PE and walk its `previous` chain — visiting
    # branch_c → trunk_a only, never trunk_b.
    next_pe, _ = @chat.add_user_message("next on branch", "key", "gpt-5", branch_c.execution_id)

    summarized_context = nil
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "key", llm_type: "openai" } ]) do
      summarized_context, _ = @chat.send(:build_streaming_context, next_pe, "jwt")
    end

    # The branch's turns appear in the transcript; the sibling's do not.
    assert_includes summarized_context, "branch-c follow-up"
    assert_includes summarized_context, "trunk-a question"
    refute_includes summarized_context, "trunk-b sibling talk"
    refute_includes summarized_context, "trunk-b answer"
  end

  # ----- summarization_target (private) ----- #

  test "summarization_target returns [ollama_uuid, SUMMARIZATION_MODEL] when ollama+the model are available" do
    options = [
      { uuid: "openai-key", llm_type: "openai", available_models: [ { "value" => "gpt-5" } ] },
      { uuid: "ollama-local", llm_type: "ollama", available_models: [
        { "value" => "qwen3-6-35b-fast" }, { "value" => "qwen3-6-35b" }
      ] }
    ]
    assert_equal [ "ollama-local", "qwen3-6-35b-fast" ],
                 @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is missing from llm_options" do
    options = [ { uuid: "k", llm_type: "openai", available_models: [] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is present but SUMMARIZATION_MODEL is not in its catalog" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { "value" => "qwen3-6-35b" }
    ] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target accepts symbol-keyed model entries too" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { value: "qwen3-6-35b-fast" }
    ] } ]
    assert_equal [ "ollama-local", "qwen3-6-35b-fast" ],
                 @chat.send(:summarization_target, options)
  end

  # ----- resolve_llm_type (private, hits ServerResource) ----- #

  test "resolve_llm_type looks up the llm_type for a given uuid via ServerResource" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k1", llm_type: "openai" },
                { uuid: "k2", llm_type: "anthropic" } ]) do
      assert_equal "anthropic", @chat.send(:resolve_llm_type, "k2", "jwt")
    end
  end

  test "resolve_llm_type returns 'unknown' when the uuid isn't in the options" do
    with_stub(LlmMetaClient::ServerResource, :available_llm_options, []) do
      assert_equal "unknown", @chat.send(:resolve_llm_type, "missing", "jwt")
    end
  end

  # ----- summarize_for_title — the "Undefined Image" bug regression guard ----- #

  test "summarize_for_title strips the leading image before calling the summarizer" do
    pe, _m = @chat.add_user_message("Describe", "key-1", "gpt-5", nil,
                                     image: { mime: "image/png", data_b64: "AAA" })
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    captured_prompt_arg = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, _uuid, _model, _ctx, body|
      captured_prompt_arg = body[:prompt]
      "A short title"
    end

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      result = @chat.send(:summarize_for_title, pe.prompt, "jwt")
      assert_equal "A short title", result
    end

    # The summarizer must NEVER see the image-markdown — that's how the
    # "Undefined Image" title used to leak in.
    refute_includes captured_prompt_arg.to_s, "data:image"
    refute_includes captured_prompt_arg.to_s, "base64"
    assert_includes captured_prompt_arg.to_s, "Describe"
  end

  test "summarize_for_title short-circuits to nil when the prompt is image-only (no text remains after strip)" do
    pe, _m = @chat.add_user_message("", "key-1", "gpt-5", nil,
                                     image: { mime: "image/png", data_b64: "AAA" })
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    called = false
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| called = true; "x" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_nil @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
    refute called, "the summarizer must not be called for an image-only prompt"
  end

  test "summarize_for_title falls back to the truncated prompt when there are no user messages yet" do
    # Without a latest PE we can't dispatch to an LLM, but we still need to
    # return *something* so chat_manager's title filter doesn't hide the chat.
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| raise "should not be called" }
    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "some text", @chat.send(:summarize_for_title, "some text", "jwt")
    end
  end

  test "summarize_for_title falls back to the truncated prompt when the LLM returns blank" do
    # Medgemma in particular wraps its response inside <unused94>…<unused95>
    # sentinels; after stripping there's nothing left, which used to leave
    # the chat title blank — and chat_manager hides untitled chats from the
    # sidebar. Verified at the strip layer too.
    pe, _m = @chat.add_user_message("Diagnose this", "key-1", "medgemma1-5-4b")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| "<unused94>thought\nreasoning\n<unused95>" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Diagnose this", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  test "summarize_for_title falls back to the truncated prompt when the LLM call raises" do
    pe, _m = @chat.add_user_message("Diagnose this", "key-1", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| raise StandardError, "boom" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Diagnose this", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  test "summarize_for_title strips markdown formatting from the LLM's reply" do
    pe, _m = @chat.add_user_message("Hello world", "key-1", "gpt-5")
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)

    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| "**Greeting**" }

    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_equal "Greeting", @chat.send(:summarize_for_title, pe.prompt, "jwt")
    end
  end

  # ----- strip_title_markdown (private) ----- #

  test "strip_title_markdown removes ** ** bold emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "**Greeting**")
  end

  test "strip_title_markdown removes * * italic emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "*Greeting*")
  end

  test "strip_title_markdown removes __ __ and _ _ underscore emphasis" do
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "__Greeting__")
    assert_equal "Greeting", @chat.send(:strip_title_markdown, "_Greeting_")
  end

  test "strip_title_markdown removes inline `code` backticks" do
    assert_equal "Run bin/dev", @chat.send(:strip_title_markdown, "Run `bin/dev`")
  end

  test "strip_title_markdown removes a leading # heading marker" do
    assert_equal "My title", @chat.send(:strip_title_markdown, "# My title")
    assert_equal "Sub title", @chat.send(:strip_title_markdown, "### Sub title")
  end

  test "strip_title_markdown strips wrapping straight and curly quotes" do
    assert_equal "Hello", @chat.send(:strip_title_markdown, '"Hello"')
    assert_equal "Hello", @chat.send(:strip_title_markdown, "'Hello'")
    assert_equal "Hello", @chat.send(:strip_title_markdown, "“Hello”")
    assert_equal "Hello", @chat.send(:strip_title_markdown, "「Hello」")
  end

  test "strip_title_markdown returns plain text untouched" do
    assert_equal "A simple title", @chat.send(:strip_title_markdown, "A simple title")
  end

  test "strip_title_markdown returns empty string for nil and empty input (does not raise)" do
    assert_equal "", @chat.send(:strip_title_markdown, nil)
    assert_equal "", @chat.send(:strip_title_markdown, "")
  end

  test "strip_title_markdown drops Gemma <unused94>...<unused95> reasoning blocks" do
    raw = "<unused94>thought\nHere's a thinking process for analyzing the chest X-ray.\n<unused95>Chest X-ray findings"
    assert_equal "Chest X-ray findings", @chat.send(:strip_title_markdown, raw)
  end

  test "strip_title_markdown removes orphaned <unusedNN> tokens when the close sentinel is missing" do
    assert_equal "Some title", @chat.send(:strip_title_markdown, "<unused94>Some title")
    assert_equal "Title", @chat.send(:strip_title_markdown, "<unused42>Title")
  end

  # ----- finalize_streamed_response ----- #

  test "finalize_streamed_response skips persistence when content is blank" do
    pe, _m = @chat.add_user_message("hi", "k", "gpt-5")

    assert_no_difference -> { @chat.messages.count } do
      assert_nil @chat.finalize_streamed_response(pe, "", "jwt")
      assert_nil @chat.finalize_streamed_response(pe, nil, "jwt")
    end
  end

  test "finalize_streamed_response persists the content + creates an assistant message when content present" do
    pe, _m = @chat.add_user_message("hi", "k", "gpt-5", nil, llm_platform: "openai")

    with_stub(LlmMetaClient::ServerResource, :available_llm_options, [ { uuid: "k", llm_type: "openai" } ]) do
      assert_difference -> { @chat.messages.where(role: "assistant").count }, 1 do
        msg = @chat.finalize_streamed_response(pe, "the response", "jwt")
        assert msg.persisted?
        assert_equal "assistant", msg.role
      end
    end

    assert_equal "the response", pe.reload.response
    # llm_platform was already set on the PE; it must not be overwritten.
    assert_equal "openai", pe.llm_platform
  end

  test "finalize_streamed_response resolves llm_platform from llm_uuid when the PE has none yet" do
    pe = PromptNavigator::PromptExecution.create!(
      prompt: "hi", llm_uuid: "key-1", model: "gpt-5",
      llm_platform: nil, configuration: ""
    )
    @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)

    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "key-1", llm_type: "openai" } ]) do
      @chat.finalize_streamed_response(pe, "r", "jwt")
    end

    assert_equal "openai", pe.reload.llm_platform
  end

  test "finalize_streamed_response is idempotent: second call with the same PE returns the existing message and creates no duplicate" do
    pe = PromptNavigator::PromptExecution.create!(prompt: "p", llm_platform: "openai", configuration: "")
    @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)

    first  = @chat.finalize_streamed_response(pe, "response text", "jwt")
    second = @chat.finalize_streamed_response(pe, "response text", "jwt")

    assert_equal first.id, second.id
    assert_equal 1, @chat.messages.where(role: "assistant", prompt_navigator_prompt_execution_id: pe.id).count
  end

  # ----- build_streaming_context (private — token-budget decisions) ----- #

  # Builds a linear chain of N user→assistant turns on the chat, returning the
  # last (most-recent) PE. Each turn's prompt/response are "p<i>" / "r<i>".
  def build_chain(n, model: "gpt-5", llm_uuid: "key-1")
    last_pe = nil
    n.times do |i|
      pe = PromptNavigator::PromptExecution.create!(
        prompt: "p#{i + 1}", response: "r#{i + 1}",
        llm_uuid: llm_uuid, model: model, configuration: "", previous_id: last_pe&.id
      )
      @chat.messages.create!(role: "user", prompt_navigator_prompt_execution: pe)
      @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe)
      last_pe = pe
    end
    last_pe
  end

  # Helper to pin verbatim_count for a single test (default is 10).
  def with_verbatim_count(n)
    original = Rails.configuration.summarize_conversation_count
    Rails.configuration.summarize_conversation_count = n
    yield
  ensure
    Rails.configuration.summarize_conversation_count = original
  end

  test "build_streaming_context raises OllamaUnavailableError when no LLM options are configured" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options, []) do
      assert_raises(LlmMetaClient::Exceptions::OllamaUnavailableError) do
        @chat.send(:build_streaming_context, pe, "jwt")
      end
    end
  end

  test "build_streaming_context returns 'No context available.' for image-gen models regardless of chain depth" do
    pe = build_chain(5, model: "gemini-3-pro-image")
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      ctx, prompt = @chat.send(:build_streaming_context, pe, "jwt")
      assert_equal "No context available.", ctx
      # The current-turn prompt is still passed through.
      assert_equal "p5", prompt[:prompt]
    end
  end

  test "build_streaming_context returns 'No context available.' (+ suffix) for a root prompt with no ancestors" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      ctx, _prompt = @chat.send(:build_streaming_context, pe, "jwt")
      assert_includes ctx, "No context available."
      assert_includes ctx, "Additional prompt:"
    end
  end

  test "build_streaming_context replays ancestors verbatim when chain length <= verbatim_count" do
    # 3 turns, verbatim_count = 5 → all ancestors replayed verbatim, no summarize call.
    pe = build_chain(3)
    called_summarize = false
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| called_summarize = true; "x" }

    with_verbatim_count(5) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options,
                [ { uuid: "k", llm_type: "openai" } ]) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          ctx, _prompt = @chat.send(:build_streaming_context, pe, "jwt")
          # The leaf is the active turn; ancestors are the prior 2 PEs.
          assert_includes ctx, "User: p1\nAssistant: r1"
          assert_includes ctx, "User: p2\nAssistant: r2"
          # No summary marker should appear.
          refute_includes ctx, "Summary of earlier conversation"
        end
      end
    end
    refute called_summarize, "the summarizer must not be invoked within budget"
  end

  test "build_streaming_context summarizes the older slice and keeps the most-recent verbatim_count turns intact" do
    # 8 turns total, verbatim_count = 3 → older = 4 ancestors, recent = 3.
    # (The leaf is the active turn, so ancestors = 7. Older 4 get summarized,
    # recent 3 stay verbatim.)
    pe = build_chain(8)
    captured = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, _uuid, _model, ctx, _body|
      captured = ctx
      "older-summary"
    end

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options,
                [ { uuid: "k", llm_type: "openai" } ]) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          ctx, _prompt = @chat.send(:build_streaming_context, pe, "jwt")

          assert_includes ctx, "Summary of earlier conversation: older-summary"
          assert_includes ctx, "Recent conversation:"
          # Recent 3 of the 7 ancestors are p5..p7 (p8 is the active turn).
          assert_includes ctx, "User: p5\nAssistant: r5"
          assert_includes ctx, "User: p6\nAssistant: r6"
          assert_includes ctx, "User: p7\nAssistant: r7"
          # Older turns must NOT appear verbatim.
          refute_includes ctx, "User: p1\nAssistant: r1"
        end
      end
    end

    # The summarizer received the older slice as its context arg (the format
    # is the raw build_context array — host code passes it through).
    assert captured.is_a?(Array)
    assert_equal [ "p1", "p2", "p3", "p4" ], captured.map { |t| t[:prompt] }
  end

  test "build_streaming_context prefers the ollama qwen summarizer when available" do
    pe = build_chain(8)
    summarizer_uuid = summarizer_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      summarizer_uuid = uuid
      summarizer_model = model
      "summary"
    end

    options = [
      { uuid: "key-1", llm_type: "openai", available_models: [ { "value" => "gpt-5" } ] },
      { uuid: "ollama-local", llm_type: "ollama", available_models: [
        { "value" => "qwen3-6-35b-fast" }, { "value" => "qwen3-6-35b" }
      ] }
    ]

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options, options) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          @chat.send(:build_streaming_context, pe, "jwt")
        end
      end
    end

    assert_equal "ollama-local", summarizer_uuid
    assert_equal "qwen3-6-35b-fast", summarizer_model
  end

  test "build_streaming_context falls back to the user's own model when ollama qwen isn't available" do
    pe = build_chain(8)
    summarizer_uuid = summarizer_model = nil
    fake_query = Object.new
    fake_query.define_singleton_method(:call) do |_jwt, uuid, model, _ctx, _body|
      summarizer_uuid = uuid
      summarizer_model = model
      "summary"
    end

    # No ollama in the options at all → summarization_target returns nil.
    options = [ { uuid: "key-1", llm_type: "openai", available_models: [] } ]

    with_verbatim_count(3) do
      with_stub(LlmMetaClient::ServerResource, :available_llm_options, options) do
        with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
          @chat.send(:build_streaming_context, pe, "jwt")
        end
      end
    end

    assert_equal "key-1", summarizer_uuid
    assert_equal "gpt-5", summarizer_model
  end

  test "build_streaming_context appends the tool-error directive only when with_tools: true" do
    pe = build_chain(1)
    with_stub(LlmMetaClient::ServerResource, :available_llm_options,
              [ { uuid: "k", llm_type: "openai" } ]) do
      ctx_no_tools, _ = @chat.send(:build_streaming_context, pe, "jwt", with_tools: false)
      ctx_tools, _ = @chat.send(:build_streaming_context, pe, "jwt", with_tools: true)

      refute_includes ctx_no_tools, "tool call returns an error"
      assert_includes ctx_tools, "tool call returns an error"
      # Both still carry the always-on Additional-prompt suffix.
      assert_includes ctx_no_tools, "Additional prompt:"
      assert_includes ctx_tools, "Additional prompt:"
    end
  end
end
