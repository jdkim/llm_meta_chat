# frozen_string_literal: true

# Teaches PromptNavigator the catalog's display names.
#
# PromptNavigator labels a turn by its *platform* ("GPT", "Claude", "Gemini",
# "Ollama"). That reads as a model name for the hosted providers by accident of
# branding, but Ollama is a runtime, not a model family: a Qwen answer was
# labelled "Ollama", and so would a Llama or Gemma one.
#
# The right label already exists — the hub's catalog calls it "Qwen3.6 35B" —
# and this app already receives it on every page render for the model picker.
# `config.model_labels` is checked before the platform label and is used by
# both the message bubble and the History sidebar, so registering the catalog's
# names there fixes both, with no per-model configuration to maintain.
class ModelLabelRegistry
  # Extracts {meta_id => display label} from the llm_families payload and
  # merges it into PromptNavigator's config. Returns what it registered.
  #
  # The catalog wins over anything already registered: it is the live source,
  # and a stale label is worse than a changed one. Writes are idempotent —
  # the same meta_id always maps to the same string — so merging from several
  # request threads is safe.
  def self.register(llm_families)
    labels = extract(llm_families)
    PromptNavigator.config.model_labels.merge!(labels) if labels.any?
    labels
  end

  def self.extract(llm_families)
    Array(llm_families).each_with_object({}) do |family, labels|
      Array(family[:api_keys]).each do |key|
        Array(key[:available_models]).each do |model|
          meta_id = model["value"].to_s
          label   = model["label"].to_s
          next if meta_id.empty? || label.empty?

          labels[meta_id] = label
        end
      end
    end
  end
end
