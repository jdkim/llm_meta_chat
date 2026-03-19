import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="generation-settings"
export default class extends Controller {
  static targets = [
    "toggleButton",
    "toggleIcon",
    "panel",
    "temperatureRange",
    "temperatureValue",
    "topKRange",
    "topKValue",
    "topPRange",
    "topPValue",
    "maxTokensInput",
    "repeatPenaltyRange",
    "repeatPenaltyValue",
  ]

  connect() {
    this.expanded = false
  }

  toggle() {
    if (!this.hasPanelTarget) return

    this.expanded = !this.expanded
    this.panelTarget.style.display = this.expanded ? "block" : "none"

    if (this.hasToggleIconTarget) {
      this.toggleIconTarget.classList.toggle("bi-chevron-down", !this.expanded)
      this.toggleIconTarget.classList.toggle("bi-chevron-up", this.expanded)
    }
  }

  updateTemperature() {
    this.temperatureValueTarget.textContent = this.temperatureRangeTarget.value
  }

  updateTopK() {
    this.topKValueTarget.textContent = this.topKRangeTarget.value
  }

  updateTopP() {
    this.topPValueTarget.textContent = this.topPRangeTarget.value
  }

  updateRepeatPenalty() {
    this.repeatPenaltyValueTarget.textContent = this.repeatPenaltyRangeTarget.value
  }
}
