require "test_helper"

# A turn used to be labelled by its platform, so every local model read as
# "Ollama" whether it was Qwen, Llama or Gemma. The catalog already carries the
# right name and this app already receives it for the model picker.
class ModelLabelRegistryTest < ActiveSupport::TestCase
  FAMILIES = [
    { llm_type: "ollama", api_keys: [ { uuid: "ollama-local", available_models: [
      { "value" => "qwen3-6-35b",      "label" => "Qwen3.6 35B" },
      { "value" => "qwen3-6-35b-fast", "label" => "Qwen3.6 35B Fast" }
    ] } ] },
    { llm_type: "openai", api_keys: [ { uuid: "k1", available_models: [
      { "value" => "gpt-5-6-luna", "label" => "GPT 5.6 Luna" }
    ] } ] }
  ].freeze

  setup do
    @original = PromptNavigator.config.model_labels.dup
  end

  teardown do
    PromptNavigator.config.model_labels.replace(@original)
  end

  test "extracts meta_id => catalog label across every family" do
    labels = ModelLabelRegistry.extract(FAMILIES)

    assert_equal "Qwen3.6 35B", labels["qwen3-6-35b"]
    assert_equal "GPT 5.6 Luna", labels["gpt-5-6-luna"]
    assert_equal 3, labels.size
  end

  test "registers them so PromptNavigator labels the model, not the platform" do
    ModelLabelRegistry.register(FAMILIES)

    assert_equal "Qwen3.6 35B",
                 PromptNavigator.label_for(platform: "ollama", model: "qwen3-6-35b")
  end

  test "leaves the platform label for a model it has never seen" do
    ModelLabelRegistry.register(FAMILIES)

    assert_equal "Ollama", PromptNavigator.label_for(platform: "ollama", model: "not-in-catalog")
  end

  test "skips entries missing a value or a label" do
    families = [ { llm_type: "ollama", api_keys: [ { available_models: [
      { "value" => "",       "label" => "Nameless" },
      { "value" => "no-lbl", "label" => "" },
      { "value" => "ok",     "label" => "Fine" }
    ] } ] } ]

    assert_equal({ "ok" => "Fine" }, ModelLabelRegistry.extract(families))
  end

  test "tolerates an empty or malformed payload" do
    assert_equal({}, ModelLabelRegistry.extract(nil))
    assert_equal({}, ModelLabelRegistry.extract([]))
    assert_equal({}, ModelLabelRegistry.extract([ { llm_type: "ollama" } ]))
  end

  test "is idempotent — re-registering the same catalog changes nothing" do
    first  = ModelLabelRegistry.register(FAMILIES)
    second = ModelLabelRegistry.register(FAMILIES)

    assert_equal first, second
    assert_equal "Qwen3.6 35B", PromptNavigator.config.model_labels["qwen3-6-35b"]
  end

  test "a renamed model in the catalog wins over the previously registered name" do
    ModelLabelRegistry.register(FAMILIES)
    renamed = [ { llm_type: "ollama", api_keys: [ { available_models: [
      { "value" => "qwen3-6-35b", "label" => "Qwen3.6 35B (retired)" }
    ] } ] } ]

    ModelLabelRegistry.register(renamed)

    assert_equal "Qwen3.6 35B (retired)",
                 PromptNavigator.label_for(platform: "ollama", model: "qwen3-6-35b")
  end
end
