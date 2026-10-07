require "test_helper"

# A turn records what the catalog called its model at the time it ran.
#
# The history sidebar used to resolve that label from the LIVE catalog, so the
# label described what is offered today rather than what actually answered.
# Retiring a model silently rewrote history: on production, 350 of 520 turns had
# decayed to the bare platform name, including Ollama-hosted ones showing
# "Ollama" — the exact case the per-model label exists to fix.
class ModelLabelCaptureTest < ActiveSupport::TestCase
  setup do
    @original = PromptNavigator.config.model_labels.dup
    PromptNavigator.config.model_labels.replace("qwen3-6-35b" => "Qwen3.6 35B")
    @chat = Chat.create!(uuid: SecureRandom.uuid)
  end

  teardown { PromptNavigator.config.model_labels.replace(@original) }

  test "a new turn stores the catalog's label for its model" do
    pe, = @chat.add_user_message("hi", "uuid-1", "qwen3-6-35b", llm_platform: "ollama")
    assert_equal "Qwen3.6 35B", pe.reload.model_label
  end

  test "the stored label survives the model leaving the catalog" do
    pe, = @chat.add_user_message("hi", "uuid-1", "qwen3-6-35b", llm_platform: "ollama")
    PromptNavigator.config.model_labels.replace({})   # the model is retired

    assert_equal "Qwen3.6 35B", pe.reload.display_label,
                 "a retired model must not drag its history down to the platform name"
  end

  test "an unregistered model stores nothing rather than freezing the platform name" do
    # Writing "Ollama" here would be worse than writing nothing: the row could
    # never improve, even once the catalog knows the model.
    pe, = @chat.add_user_message("hi", "uuid-1", "a-model-not-in-the-catalog", llm_platform: "ollama")
    assert_nil pe.reload.model_label
    assert_equal "Ollama", pe.display_label
  end

  test "a row written while the registry was cold is filled in on the streamed response" do
    PromptNavigator.config.model_labels.replace({})            # cold worker
    pe, = @chat.add_user_message("hi", "uuid-1", "qwen3-6-35b", llm_platform: "ollama")
    assert_nil pe.reload.model_label

    PromptNavigator.config.model_labels.replace("qwen3-6-35b" => "Qwen3.6 35B")
    @chat.finalize_streamed_response(pe, "an answer", "jwt")

    assert_equal "Qwen3.6 35B", pe.reload.model_label
  end
end
