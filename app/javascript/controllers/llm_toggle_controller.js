import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="llm-toggle"
// Collapsible wrapper around the "Other models" grid panel. Label is
// static — the currently picked model is shown by the quick-picks row.
export default class extends Controller {
  static targets = ["toggleButton", "toggleIcon", "panel", "label"]

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

}
