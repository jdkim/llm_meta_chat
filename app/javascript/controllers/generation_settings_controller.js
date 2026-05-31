import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="generation-settings"
//
// The client-side validator only checks that the input is a JSON object;
// keys and value types are pass-through (matches the server: anything
// goes, and the provider gem decides which keys it understands).
export default class extends Controller {
  static targets = [
    "toggleButton",
    "toggleIcon",
    "panel",
    "jsonInput",
    "error",
  ]

  connect() {
    this.expanded = false
  }

  toggle() {
    if (!this.hasPanelTarget) return

    this.expanded = !this.expanded
    this.panelTarget.style.display = this.expanded ? "block" : "none"

    if (this.hasToggleIconTarget) {
      this.toggleIconTarget.classList.toggle("bi-chevron-up", !this.expanded)
      this.toggleIconTarget.classList.toggle("bi-chevron-down", this.expanded)
    }

    if (this.expanded) this.dispatch("opened", { bubbles: true })
  }

  validate() {
    const input = this.jsonInputTarget.value.trim()

    if (!input) {
      this.#clearError()
      return
    }

    let parsed
    try {
      parsed = JSON.parse(input)
    } catch (e) {
      this.#showError("Invalid JSON syntax")
      return
    }

    if (typeof parsed !== "object" || Array.isArray(parsed) || parsed === null) {
      this.#showError("Must be a JSON object (e.g. {\"temperature\": 0.7})")
      return
    }

    this.#clearError()
  }

  get isValid() {
    if (!this.hasJsonInputTarget) return true
    const input = this.jsonInputTarget.value.trim()
    if (!input) return true

    try {
      const parsed = JSON.parse(input)
      return typeof parsed === "object" && !Array.isArray(parsed) && parsed !== null
    } catch {
      return false
    }
  }

  #showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message
      this.errorTarget.style.display = "block"
    }
    this.jsonInputTarget.classList.add("generation-settings-json-input--invalid")
  }

  #clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = ""
      this.errorTarget.style.display = "none"
    }
    this.jsonInputTarget.classList.remove("generation-settings-json-input--invalid")
  }
}
