import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="llm-selector"
export default class extends Controller {
  static targets = ["family", "apiKey", "model"]

  connect() {
    this.#setDefaults()
    this.dispatch("changed")
  }

  familyChanged(event) {
    const selectedFamily = event.target.value
    const familiesData = event.target.dataset.families

    if (!selectedFamily || !familiesData) {
      this.#showApiKeyField()
      this.#clearApiKeySelect()
      this.#clearModelSelect()
      return
    }

    try {
      const families = JSON.parse(familiesData)
      const family = families.find((f) => f.llm_type === selectedFamily)

      if (family?.api_keys) {
        if (selectedFamily === "ollama") {
          // Ollama: skip API key selection entirely, go straight to model
          const apiKey = family.api_keys[0]
          this.#hideApiKeyField()
          this.apiKeyTarget.disabled = false
          this.apiKeyTarget.innerHTML =
            `<option value="${apiKey.uuid}" selected>${apiKey.description}</option>`
          if (apiKey.available_models) {
            this.#populateModelSelect(apiKey.available_models)
          } else {
            this.#clearModelSelect()
          }
        } else {
          this.#showApiKeyField()
          this.#populateApiKeySelect(family.api_keys)
        }
      } else {
        this.#showApiKeyField()
        this.#clearApiKeySelect()
        this.#clearModelSelect()
      }
    } catch (e) {
      console.error("Failed to parse families data:", e)
      this.#clearApiKeySelect()
      this.#clearModelSelect()
    }
  }

  apiKeyChanged(event) {
    const selectedValue = event.target.value
    const familiesData = this.hasFamilyTarget
      ? this.familyTarget.dataset.families
      : null
    const selectedFamily = this.hasFamilyTarget
      ? this.familyTarget.value
      : null

    if (!selectedValue || !familiesData || !selectedFamily) {
      this.#clearModelSelect()
      return
    }

    try {
      const families = JSON.parse(familiesData)
      const family = families.find((f) => f.llm_type === selectedFamily)
      const selectedKey = family?.api_keys?.find(
        (k) => k.uuid === selectedValue
      )

      if (selectedKey?.available_models) {
        this.#populateModelSelect(selectedKey.available_models)
      } else {
        this.#clearModelSelect()
      }
    } catch (e) {
      console.error("Failed to parse families data:", e)
      this.#clearModelSelect()
    }
  }

  #setDefaults() {
    const urlParams = new URLSearchParams(window.location.search)
    const defaultFamily = urlParams.get("family")
    const defaultApiKey = urlParams.get("api_key_uuid")
    const defaultModel = urlParams.get("model")

    if (defaultFamily && this.hasFamilyTarget) {
      const familyOption = Array.from(this.familyTarget.options).find(
        (o) => o.value === defaultFamily
      )
      if (familyOption) {
        this.familyTarget.value = familyOption.value
        this.familyChanged({ target: this.familyTarget })

        if (defaultFamily === "ollama") {
          // Ollama: API key is auto-selected by familyChanged, just set model
          if (defaultModel && this.hasModelTarget) {
            const modelOption = Array.from(this.modelTarget.options).find(
              (o) => o.value === defaultModel
            )
            if (modelOption) {
              this.modelTarget.value = modelOption.value
            }
          }
        } else if (defaultApiKey && this.hasApiKeyTarget) {
          const apiKeyOption = Array.from(this.apiKeyTarget.options).find(
            (o) => o.value === defaultApiKey
          )
          if (apiKeyOption) {
            this.apiKeyTarget.value = apiKeyOption.value
            this.apiKeyChanged({ target: this.apiKeyTarget })

            if (defaultModel && this.hasModelTarget) {
              const modelOption = Array.from(this.modelTarget.options).find(
                (o) => o.value === defaultModel
              )
              if (modelOption) {
                this.modelTarget.value = modelOption.value
              }
            }
          }
        }
      }
    } else if (defaultApiKey && this.hasFamilyTarget) {
      // Fallback: try to find the family from the API key UUID
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

          if (family.llm_type !== "ollama") {
            this.apiKeyTarget.value = apiKeyUuid
            this.apiKeyChanged({ target: this.apiKeyTarget })
          }

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

  #populateApiKeySelect(apiKeys) {
    if (!this.hasApiKeyTarget) return

    this.apiKeyTarget.innerHTML =
      '<option value="">Please select a family</option>'
    this.apiKeyTarget.disabled = false

    for (const key of apiKeys) {
      const option = document.createElement("option")
      option.value = key.uuid
      option.textContent = key.description
      this.apiKeyTarget.appendChild(option)
    }

    // Clear model when API key list changes
    this.#clearModelSelect()
    this.dispatch("changed")
  }

  #clearApiKeySelect() {
    if (!this.hasApiKeyTarget) return

    this.apiKeyTarget.innerHTML =
      '<option value="">Please select a provider first</option>'
    this.apiKeyTarget.disabled = true
    this.#clearModelSelect()
    this.dispatch("changed")
  }

  #hideApiKeyField() {
    if (!this.hasApiKeyTarget) return
    this.apiKeyTarget.closest(".api-key-field").classList.add("hidden")
  }

  #showApiKeyField() {
    if (!this.hasApiKeyTarget) return
    this.apiKeyTarget.closest(".api-key-field").classList.remove("hidden")
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
      this.modelTarget.appendChild(option)
    }

    this.dispatch("changed")
  }

  #clearModelSelect() {
    if (!this.hasModelTarget) return

    this.modelTarget.innerHTML =
      '<option value="">Please select a family first</option>'
    this.modelTarget.disabled = true
    this.dispatch("changed")
  }
}
