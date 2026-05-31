import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="model-picker"
//
// Replaces the previous cascading family → api_key → model dropdowns
// with a single mechanism that backs both:
//   * the quick-picks row below the prompt (Default + favorites), and
//   * the "Other models" grid panel.
//
// Every clickable element (`.quick-pick-button`, `.model-grid-cell`)
// carries `data-family`, `data-api-key-uuid`, `data-model`, and
// `data-supports-vision`. Clicking writes those values into hidden form
// fields (`family`, `api_key_uuid`, `model`) so the chat form submits
// exactly what the meta-server's API expects.
//
// On connect it picks a sensible initial selection: the user's default
// (the .is-default button) if present, otherwise the first quick-pick,
// otherwise the first grid cell.
export default class extends Controller {
  static targets = ["family", "apiKey", "model", "supportsVision", "quickPicks"]

  connect() {
    this.#pickInitial()
  }

  // Action: data-action="click->model-picker#pick"
  pick(event) {
    const el = event.currentTarget
    this.#applySelection({
      family:           el.dataset.family,
      apiKeyUuid:       el.dataset.apiKeyUuid,
      model:            el.dataset.model,
      supportsVision:   el.dataset.supportsVision === "true",
      label:            this.#labelFor(el),
    })

    // If the click came from inside the "Other models" panel, collapse
    // it now that a selection has been made.
    const panel = el.closest('.llm-toggle-panel')
    if (panel && panel.style.display !== "none") {
      const toggle = panel.closest('.llm-toggle-field')
      const toggleButton = toggle?.querySelector('.llm-toggle-button')
      toggleButton?.click()
    }
  }

  #pickInitial() {
    // Prefer the marked default if it's present in the quick-picks row.
    const defaultBtn = this.element.querySelector(".quick-pick-button.is-default")
    if (defaultBtn) { this.#clickAsPick(defaultBtn); return }
    const firstQuick = this.element.querySelector(".quick-pick-button")
    if (firstQuick) { this.#clickAsPick(firstQuick); return }
    const firstCell = this.element.querySelector(".model-grid-cell")
    if (firstCell) { this.#clickAsPick(firstCell) }
  }

  // Apply the same logic as a real click without firing the user-event
  // side effects (collapsing the panel). Used at #connect time.
  #clickAsPick(el) {
    this.#applySelection({
      family:           el.dataset.family,
      apiKeyUuid:       el.dataset.apiKeyUuid,
      model:            el.dataset.model,
      supportsVision:   el.dataset.supportsVision === "true",
      label:            this.#labelFor(el),
    })
  }

  #applySelection({ family, apiKeyUuid, model, supportsVision, label }) {
    if (this.hasFamilyTarget) this.familyTarget.value = family || ""
    if (this.hasApiKeyTarget) this.apiKeyTarget.value = apiKeyUuid || ""
    if (this.hasModelTarget) {
      this.modelTarget.value = model || ""
      // Expose supports_vision via a dataset attribute on the model
      // input — chats_form_controller reads it to drive the attach
      // button's enabled state (vision-only models accept images).
      this.modelTarget.dataset.supportsVision = supportsVision ? "true" : "false"
    }

    // If the picked model has no representation in the quick-picks row
    // (i.e. came from the grid and isn't a favorite / default), add a
    // transient pill so the user always sees what's currently selected.
    if (model) this.#ensureQuickPickFor({ family, apiKeyUuid, model, supportsVision, label })

    // Mark the picked element(s) as selected; clear others. Match by
    // data-model so any other button representing the same model (e.g.,
    // the same favorite appearing in both the quick-picks row and the
    // grid cell) also highlights.
    this.element.querySelectorAll(".quick-pick-button.is-selected, .model-grid-cell.is-selected")
      .forEach((el) => el.classList.remove("is-selected"))
    if (model) {
      this.element.querySelectorAll(`[data-model="${CSS.escape(model)}"]`)
        .forEach((el) => el.classList.add("is-selected"))
    }

    // Tell chats-form to refresh the send button / attach button state.
    this.dispatch("changed", { bubbles: true })
  }

  // Inject a transient `.quick-pick-button.is-transient` into the row
  // when the picked model isn't already represented there. At most one
  // transient pill exists at a time — it's replaced on each grid pick.
  #ensureQuickPickFor({ family, apiKeyUuid, model, supportsVision, label }) {
    if (!this.hasQuickPicksTarget) return
    const existing = this.quickPicksTarget.querySelector(
      `.quick-pick-button[data-model="${CSS.escape(model)}"]`
    )
    if (existing) {
      // Already in the row (default or favorite). Drop any stale
      // transient pill so we don't leave a duplicate of a previous pick.
      this.quickPicksTarget.querySelectorAll(".quick-pick-button.is-transient")
        .forEach((el) => el.remove())
      return
    }
    // Otherwise rebuild the single transient slot.
    this.quickPicksTarget.querySelectorAll(".quick-pick-button.is-transient")
      .forEach((el) => el.remove())
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "quick-pick-button is-transient"
    btn.title = model
    btn.dataset.family = family || ""
    btn.dataset.apiKeyUuid = apiKeyUuid || ""
    btn.dataset.model = model
    btn.dataset.supportsVision = supportsVision ? "true" : "false"
    btn.dataset.action = `click->${this.identifier}#pick`
    btn.textContent = label || model
    this.quickPicksTarget.appendChild(btn)
  }

  #labelFor(el) {
    // Grid cells wrap the name in `.model-grid-label`; quick-pick
    // buttons just put text directly inside. Either way, trim it.
    const gridLabel = el.querySelector?.(".model-grid-label")
    return (gridLabel?.textContent || el.textContent || "").trim()
  }
}
