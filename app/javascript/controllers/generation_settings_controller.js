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
    "countBadge",
  ]

  connect() {
    this.expanded = false
    this.#updateCountBadge()
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
      this.#updateCountBadge()
      return
    }

    let parsed
    try {
      parsed = JSON.parse(input)
    } catch (e) {
      this.#showError("Invalid JSON syntax")
      this.#updateCountBadge()
      return
    }

    if (typeof parsed !== "object" || Array.isArray(parsed) || parsed === null) {
      this.#showError("Must be a JSON object (e.g. {\"temperature\": 0.7})")
      this.#updateCountBadge()
      return
    }

    this.#clearError()
    this.#updateCountBadge(parsed)
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

  // Count of top-level keys currently set on the (valid) Settings JSON.
  // Caller can pass the already-parsed hash to avoid a second JSON.parse;
  // when omitted we re-parse the textarea (and treat invalid / empty as 0).
  #updateCountBadge(parsedOpt) {
    if (!this.hasCountBadgeTarget) return
    let count = 0
    if (parsedOpt && typeof parsedOpt === "object" && !Array.isArray(parsedOpt)) {
      count = Object.keys(parsedOpt).length
    } else if (this.hasJsonInputTarget) {
      const input = this.jsonInputTarget.value.trim()
      if (input) {
        try {
          const parsed = JSON.parse(input)
          if (typeof parsed === "object" && !Array.isArray(parsed) && parsed !== null) {
            count = Object.keys(parsed).length
          }
        } catch { /* invalid → 0 */ }
      }
    }
    this.countBadgeTarget.textContent = count
    this.countBadgeTarget.style.display = count > 0 ? "inline-block" : "none"
  }
}
