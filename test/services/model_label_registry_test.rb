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
    # The test environment uses :null_store, where every read returns nil, so
    # the caching path would be invisible. Swap in a real store for these.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    PromptNavigator.config.model_labels.replace(@original)
    Rails.cache = @original_cache
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

  # The reported bug: ChatsController#create renders the History sidebar
  # without fetching the catalog, so a worker that had not yet served a chat
  # page labelled the chip "Ollama" while the message bubble — rendered by a
  # different request — showed the model. Caching closes that gap.
  test "register caches the labels so another request can warm from them" do
    ModelLabelRegistry.register(FAMILIES)
    PromptNavigator.config.model_labels.replace({})   # a fresh worker

    ModelLabelRegistry.warm!

    assert_equal "Qwen3.6 35B",
                 PromptNavigator.label_for(platform: "ollama", model: "qwen3-6-35b")
  end

  test "warm! makes no HTTP call — it must be safe on every request" do
    ModelLabelRegistry.register(FAMILIES)
    PromptNavigator.config.model_labels.replace({})

    # WebMock raises on any unstubbed connection, so this passing IS the check.
    assert_nothing_raised { ModelLabelRegistry.warm! }
  end

  test "warm! is a no-op on a cold cache rather than an error" do
    Rails.cache.delete(ModelLabelRegistry::CACHE_KEY)

    assert_equal({}, ModelLabelRegistry.warm!)
  end

  test "register merges into the cache rather than replacing it" do
    ModelLabelRegistry.register(FAMILIES)
    ModelLabelRegistry.register([ { llm_type: "google", api_keys: [ { available_models: [
      { "value" => "gemini-3-1-pro", "label" => "Gemini 3.1 Pro" }
    ] } ] } ])

    cached = ModelLabelRegistry.cached
    assert_equal "Qwen3.6 35B", cached["qwen3-6-35b"], "earlier labels must survive"
    assert_equal "Gemini 3.1 Pro", cached["gemini-3-1-pro"]
  end

  # Production had solid_cache configured without its tables, so the first
  # cache write raised and every page fell into ChatsController#new's rescue:
  # "Chat service is currently unavailable". A cosmetic label must never do
  # that again, whatever the cache is doing.
  test "register survives a cache that raises, and still labels the model" do
    broken = Object.new
    def broken.read(*) = raise(ArgumentError, "No unique index found for key_hash")
    def broken.write(*, **) = raise(ArgumentError, "No unique index found for key_hash")
    Rails.cache = broken

    assert_nothing_raised { ModelLabelRegistry.register(FAMILIES) }
    assert_equal "Qwen3.6 35B",
                 PromptNavigator.label_for(platform: "ollama", model: "qwen3-6-35b")
  end

  test "warm! survives a cache that raises" do
    broken = Object.new
    def broken.read(*) = raise(ArgumentError, "No unique index found for key_hash")
    Rails.cache = broken

    assert_equal({}, ModelLabelRegistry.warm!)
  end
end
