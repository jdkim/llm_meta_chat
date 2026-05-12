import { Controller } from "@hotwired/stimulus"

const ALLOWED_KEYS = ["temperature", "top_k", "top_p", "max_tokens", "repeat_penalty"]

// Connects to data-controller="generation-settings"
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

    const unknownKeys = Object.keys(parsed).filter(k => !ALLOWED_KEYS.includes(k))
    if (unknownKeys.length > 0) {
      this.#showError(`Unknown keys: ${unknownKeys.join(", ")}`)
      return
    }

    const nonNumeric = Object.entries(parsed).filter(([, v]) => typeof v !== "number")
    if (nonNumeric.length > 0) {
      this.#showError(`Values must be numeric: ${nonNumeric.map(([k]) => k).join(", ")}`)
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
      if (typeof parsed !== "object" || Array.isArray(parsed) || parsed === null) return false
      if (Object.keys(parsed).some(k => !ALLOWED_KEYS.includes(k))) return false
      if (Object.values(parsed).some(v => typeof v !== "number")) return false
      return true
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
