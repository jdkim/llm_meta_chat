# Override the prompt_navigator engine's per-model badge labels.
# These take precedence over the per-platform default ("Ollama") so the
# history sidebar shows the model family instead of just the provider.
PromptNavigator.configure do |c|
  c.model_labels["qwen3-6-35b"]      = "Qwen"
  c.model_labels["qwen3-6-35b-fast"] = "Qwen"
  c.model_labels["medgemma1-5-4b"]   = "MedGemma"
end
