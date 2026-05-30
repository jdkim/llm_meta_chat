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

  # ----- ordered_messages + ordered_by_descending_prompt_executions ----- #

  test "ordered_messages returns messages in created_at ascending order" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    pe2, m2 = @chat.add_user_message("second", "k", "gpt-5")

    ordered = @chat.ordered_messages.to_a
    assert_equal [ m1.id, m2.id ], ordered.map(&:id)
  end

  test "ordered_by_descending_prompt_executions returns only user-role PEs, newest first" do
    pe1, m1 = @chat.add_user_message("first", "k", "gpt-5")
    # Manually add an assistant message — shouldn't appear in this list.
    @chat.messages.create!(role: "assistant", prompt_navigator_prompt_execution: pe1)
    pe2, _m2 = @chat.add_user_message("second", "k", "gpt-5")

    pes = @chat.ordered_by_descending_prompt_executions
    assert_equal [ pe2.id, pe1.id ], pes.map(&:id)
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

  # ----- summarization_target (private) ----- #

  test "summarization_target returns [ollama_uuid, qwen3-5-4b] when ollama+qwen are available" do
    options = [
      { uuid: "openai-key", llm_type: "openai", available_models: [ { "value" => "gpt-5" } ] },
      { uuid: "ollama-local", llm_type: "ollama", available_models: [
        { "value" => "qwen3-5-4b" }, { "value" => "qwen3-5-9b" }
      ] }
    ]
    assert_equal [ "ollama-local", "qwen3-5-4b" ],
                 @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is missing from llm_options" do
    options = [ { uuid: "k", llm_type: "openai", available_models: [] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target returns nil when ollama is present but qwen3-5-4b is not in its catalog" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { "value" => "qwen3-5-9b" }
    ] } ]
    assert_nil @chat.send(:summarization_target, options)
  end

  test "summarization_target accepts symbol-keyed model entries too" do
    options = [ { uuid: "ollama-local", llm_type: "ollama", available_models: [
      { value: "qwen3-5-4b" }
    ] } ]
    assert_equal [ "ollama-local", "qwen3-5-4b" ],
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

  test "summarize_for_title returns nil when there are no user messages yet" do
    fake_query = Object.new
    fake_query.define_singleton_method(:call) { |*| raise "should not be called" }
    with_stub(LlmMetaClient::ServerQuery, :new, fake_query) do
      assert_nil @chat.send(:summarize_for_title, "some text", "jwt")
    end
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
end
