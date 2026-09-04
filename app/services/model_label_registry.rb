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
  CACHE_KEY = "model_label_registry/v1"
  CACHE_TTL = 30.minutes

  # Extracts {meta_id => display label} from the llm_families payload, caches
  # it, and merges it into PromptNavigator's config. Returns what it extracted.
  #
  # The catalog wins over anything already registered: it is the live source,
  # and a stale label is worse than a changed one. Writes are idempotent —
  # the same meta_id always maps to the same string — so merging from several
  # request threads is safe.
  def self.register(llm_families)
    labels = extract(llm_families)
    return labels if labels.empty?

    merged = cached.merge(labels)
    Rails.cache.write(CACHE_KEY, merged, expires_in: CACHE_TTL)
    PromptNavigator.config.model_labels.merge!(merged)
    labels
  end

  # Makes sure this process knows the labels, whatever the current request is
  # doing. PromptNavigator's config is process-global, so registering it only
  # in the actions that happen to fetch the catalog left gaps: ChatsController
  # #create renders the History sidebar without fetching, so a chip rendered
  # by a worker that had not yet served a chat page fell back to the platform
  # label ("Ollama") while the message bubble, rendered by another request,
  # showed the model. Reads the shared cache first; only a cold cache costs an
  # HTTP call.
  # Deliberately cache-only: it must not make an HTTP call. This runs on every
  # request, streaming ones included, and labels are cosmetic — they are not
  # worth a network round trip on the critical path. The cache is filled by
  # `register` from the pages that fetch the catalog anyway, and prod's cache
  # is shared across workers, so one chat-page render teaches every worker.
  def self.warm!
    labels = cached
    PromptNavigator.config.model_labels.merge!(labels) if labels.any?
    labels
  end

  def self.cached
    Rails.cache.read(CACHE_KEY) || {}
  rescue StandardError
    {}
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
