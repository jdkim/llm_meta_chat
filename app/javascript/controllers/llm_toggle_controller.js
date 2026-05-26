import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="llm-toggle"
// Wraps the LLM picker (family/api_key/model) in a collapsible button that
// shows the currently selected model name. Coordinates with other input
// controls (Tools, Settings) via input-controls.
export default class extends Controller {
  static targets = ["toggleButton", "toggleIcon", "panel", "label"]

  connect() {
    this.expanded = false
    this._onLlmChanged = this.#updateLabel.bind(this)
    document.addEventListener("llm-selector:changed", this._onLlmChanged)
    this._onModelSelected = this.#closeOnModelSelected.bind(this)
    document.addEventListener("llm-selector:modelSelected", this._onModelSelected)
    this.#updateLabel()
  }

  disconnect() {
    document.removeEventListener("llm-selector:changed", this._onLlmChanged)
    document.removeEventListener("llm-selector:modelSelected", this._onModelSelected)
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

  // Auto-collapse the picker once the user actually picks a model, so they
  // don't have to click outside. Only closes on a real (non-blank) selection.
  #closeOnModelSelected() {
    if (!this.expanded) return
    const modelSelect = this.element.querySelector('select[name="model"]')
    if (modelSelect && modelSelect.value) this.toggle()
  }

  #updateLabel() {
    if (!this.hasLabelTarget) return
    const modelSelect = this.element.querySelector('select[name="model"]')
    const opt = modelSelect && modelSelect.options[modelSelect.selectedIndex]
    if (opt && opt.value) {
      this.labelTarget.textContent = opt.text
    } else {
      this.labelTarget.textContent = "Select LLM"
    }
  }
}
