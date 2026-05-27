import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="llm-selector"
export default class extends Controller {
  static targets = ["family", "apiKey", "model"]
  static values = {
    defaultFamily: { type: String, default: "" },
    defaultModel: { type: String, default: "" }
  }

  connect() {
    this.#setDefaults()
    this.dispatch("changed")
  }

  familyChanged(event) {
    const selectedFamily = event.target.value
    const familiesData = event.target.dataset.families

    if (!selectedFamily || !familiesData) {
      this.#clearApiKey()
      this.#clearModelSelect()
      return
    }

    try {
      const families = JSON.parse(familiesData)
      const family = families.find((f) => f.llm_type === selectedFamily)

      if (family?.api_keys?.length > 0) {
        // Auto-pick the first API key — the Family selection has been removed.
        const apiKey = family.api_keys[0]
        this.#setApiKey(apiKey.uuid)
        if (apiKey.available_models) {
          this.#populateModelSelect(apiKey.available_models)
        } else {
          this.#clearModelSelect()
        }
      } else {
        this.#clearApiKey()
        this.#clearModelSelect()
      }
    } catch (e) {
      console.error("Failed to parse families data:", e)
      this.#clearApiKey()
      this.#clearModelSelect()
    }
  }

  modelChanged() {
    this.dispatch("changed")
    this.dispatch("modelSelected")
  }

  // Click handler for a favorite-model button in the Favorites section of
  // the LLM toggle panel. Sets family + api_key_uuid + model in one step,
  // bypassing the Provider→Model drill-down. Dispatches modelSelected so
  // the panel auto-closes (handled by llm-toggle).
  selectFavorite(event) {
    const btn = event.currentTarget
    const family = btn.dataset.family
    const apiKeyUuid = btn.dataset.apiKeyUuid
    const modelMeta = btn.dataset.model
    if (!family || !modelMeta) return

    if (this.hasFamilyTarget) {
      const familyOption = Array.from(this.familyTarget.options).find(o => o.value === family)
      if (familyOption) {
        this.familyTarget.value = familyOption.value
        this.familyChanged({ target: this.familyTarget })
      }
    }
    if (apiKeyUuid) this.#setApiKey(apiKeyUuid)
    if (this.hasModelTarget) {
      const modelOption = Array.from(this.modelTarget.options).find(o => o.value === modelMeta)
      if (modelOption) {
        this.modelTarget.value = modelOption.value
        this.modelChanged()
      }
    }
  }

  #setDefaults() {
    const urlParams = new URLSearchParams(window.location.search)
    const defaultFamily = urlParams.get("family") || this.defaultFamilyValue
    const defaultApiKey = urlParams.get("api_key_uuid")
    const defaultModel = urlParams.get("model") || this.defaultModelValue

    if (defaultFamily && this.hasFamilyTarget) {
      const familyOption = Array.from(this.familyTarget.options).find(
        (o) => o.value === defaultFamily
      )
      if (familyOption) {
        this.familyTarget.value = familyOption.value
        this.familyChanged({ target: this.familyTarget })

        if (defaultApiKey) {
          // URL explicitly picks a different api key than family.api_keys[0]
          this.#setApiKey(defaultApiKey)
        }

        if (defaultModel && this.hasModelTarget) {
          const modelOption = Array.from(this.modelTarget.options).find(
            (o) => o.value === defaultModel
          )
          if (modelOption) {
            this.modelTarget.value = modelOption.value
          }
        }
      }
    } else if (defaultApiKey && this.hasFamilyTarget) {
      this.#setDefaultsFromApiKey(defaultApiKey, defaultModel)
    }
  }

  #setDefaultsFromApiKey(apiKeyUuid, defaultModel) {
    const familiesData = this.hasFamilyTarget
      ? this.familyTarget.dataset.families
      : null
    if (!familiesData) return

    try {
      const families = JSON.parse(familiesData)
      for (const family of families) {
        const key = family.api_keys?.find((k) => k.uuid === apiKeyUuid)
        if (key) {
          this.familyTarget.value = family.llm_type
          this.familyChanged({ target: this.familyTarget })
          this.#setApiKey(apiKeyUuid)

          if (defaultModel && this.hasModelTarget) {
            const modelOption = Array.from(this.modelTarget.options).find(
              (o) => o.value === defaultModel
            )
            if (modelOption) {
              this.modelTarget.value = modelOption.value
            }
          }
          break
        }
      }
    } catch (e) {
      console.error("Failed to set defaults from API key:", e)
    }
  }

  #setApiKey(uuid) {
    if (!this.hasApiKeyTarget) return
    this.apiKeyTarget.value = uuid
    this.dispatch("changed")
  }

  #clearApiKey() {
    if (!this.hasApiKeyTarget) return
    this.apiKeyTarget.value = ""
    this.dispatch("changed")
  }

  #populateModelSelect(models) {
    if (!this.hasModelTarget) return

    this.modelTarget.innerHTML =
      '<option value="">Please select a model</option>'
    this.modelTarget.disabled = false

    for (const model of models) {
      const option = document.createElement("option")
      option.value = model.value
      option.textContent = model.label
      // Carry vision-capability through to the DOM so chats-form can gate
      // the attach button without an extra round-trip.
      option.dataset.supportsVision = String(model.supports_vision === true)
      this.modelTarget.appendChild(option)
    }

    this.dispatch("changed")
  }

  #clearModelSelect() {
    if (!this.hasModelTarget) return

    this.modelTarget.innerHTML =
      '<option value="">Please select a provider first</option>'
    this.modelTarget.disabled = true
    this.dispatch("changed")
  }
}
