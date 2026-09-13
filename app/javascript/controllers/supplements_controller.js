import { Controller } from "@hotwired/stimulus"

// Citing history nodes as reference material for the next prompt.
//
// Ctrl/cmd+click a history card to cite it. The cited content is attached to
// the next turn as reference material — that is what the dotted arrow in the
// pane means — while the prompt itself says what to do with it. There is no
// "mode": intent is language, not state.
//
// This controller spans two regions of the page (the history pane on the right,
// the composer in the middle), which is why it is mounted on their common
// ancestor and uses a delegated click listener rather than per-card actions:
// the pane is replaced wholesale by a Turbo Stream after every prompt, and
// per-card bindings would not survive that.
export default class extends Controller {
  static targets = ["field", "chips", "presets", "prompt", "note", "preview", "reveal"]
  static values = { max: Number }

  connect() {
    this.selected = []
    this.previewOpen = false
    this.onClick = this.handleClick.bind(this)
    this.onReset = this.clear.bind(this)
    this.onPromptInput = this.refreshPresets.bind(this)

    this.element.addEventListener("click", this.onClick)
    // Fired by create.turbo_stream after a prompt is sent: the citations were
    // consumed by that prompt and do not carry over (they are a per-turn
    // annotation, not something inherited by the next one).
    document.addEventListener("supplements:reset", this.onReset)
    if (this.hasPromptTarget) {
      this.promptTarget.addEventListener("input", this.onPromptInput)
    }
    this.render()
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    document.removeEventListener("supplements:reset", this.onReset)
    if (this.hasPromptTarget) {
      this.promptTarget.removeEventListener("input", this.onPromptInput)
    }
  }

  handleClick(event) {
    // Plain clicks must keep navigating to the node. Only ctrl/cmd+click
    // selects — and it has to be cancelled explicitly, because the card row is
    // an <a> and the browser would otherwise open it in a new tab.
    if (!event.ctrlKey && !event.metaKey) return

    const card = event.target.closest(".history-card[data-uuid]")
    if (!card || !this.element.contains(card)) return

    const uuid = card.dataset.uuid
    // The Start node is synthetic and has no content to cite.
    if (!uuid || uuid === "root") return

    event.preventDefault()
    event.stopPropagation()
    this.toggle(uuid)
  }

  toggle(uuid) {
    const at = this.selected.indexOf(uuid)
    if (at === -1) {
      // The cap is enforced server-side too; this is the affordance, not the
      // guard.
      if (this.maxValue && this.selected.length >= this.maxValue) return
      this.selected.push(uuid)
    } else {
      this.selected.splice(at, 1)
    }
    this.render()
  }

  remove(event) {
    this.toggle(event.currentTarget.dataset.uuid)
  }

  clear() {
    this.selected = []
    this.previewOpen = false
    this.render()
  }

  // Presets fill the box with editable wording. Their real purpose is to show
  // how to refer to the cited material at all — "the referenced answers" only
  // resolves because the injected block numbers and labels it — so they are
  // worked examples more than shortcuts.
  applyPreset(event) {
    if (!this.hasPromptTarget) return
    this.promptTarget.value = event.currentTarget.dataset.preset || ""
    // Let the composer controller re-evaluate its submit button.
    this.promptTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.promptTarget.focus()
    this.refreshPresets()
  }

  render() {
    if (this.hasFieldTarget) this.fieldTarget.value = this.selected.join(",")
    this.markCards()
    this.renderChips()
    this.refreshPresets()
    this.refreshPreview()
  }

  togglePreview() {
    if (!this.hasPreviewTarget) return
    this.previewOpen = !this.previewOpen
    this.refreshPreview()
  }

  // Fetches the block from the server rather than assembling it here. A
  // client-side reconstruction would be a second implementation of the
  // grouping and labelling rules, free to drift from the one that actually
  // sends — which would make the preview worse than useless.
  refreshPreview() {
    if (!this.hasPreviewTarget) return

    const open = this.previewOpen && this.selected.length > 0
    this.previewTarget.hidden = !open
    if (this.hasRevealTarget) {
      this.revealTarget.textContent = this.previewOpen
        ? "hide what will be sent"
        : "show what will be sent"
    }
    if (!open) return

    const url = this.previewTarget.dataset.previewUrl
    if (!url) return

    // Tag the request so a slow response for a selection the user has since
    // changed cannot overwrite a newer one.
    const token = (this.previewToken = Symbol("preview"))
    this.previewTarget.textContent = "…"

    fetch(`${url}?supplements=${encodeURIComponent(this.selected.join(","))}`, {
      headers: { Accept: "text/plain" }
    })
      .then((res) => res.text())
      .then((text) => {
        if (this.previewToken !== token) return
        this.previewTarget.textContent = text
      })
      .catch(() => {
        if (this.previewToken !== token) return
        this.previewTarget.textContent = "(could not load the preview)"
      })
  }

  markCards() {
    for (const card of this.element.querySelectorAll(".history-card[data-uuid]")) {
      card.classList.toggle("is-supplement", this.selected.includes(card.dataset.uuid))
    }
  }

  renderChips() {
    if (!this.hasChipsTarget) return
    this.chipsTarget.replaceChildren()
    this.chipsTarget.hidden = this.selected.length === 0
    // The explainer shares the chips' visibility: it is only meaningful once
    // something is actually cited.
    if (this.hasNoteTarget) this.noteTarget.hidden = this.selected.length === 0
    if (this.selected.length === 0) return

    const label = document.createElement("span")
    label.className = "supplement-chips-label"
    label.textContent = "Referencing:"
    this.chipsTarget.appendChild(label)

    this.selected.forEach((uuid, i) => {
      const chip = document.createElement("span")
      chip.className = "supplement-chip"

      const num = document.createElement("span")
      num.className = "supplement-chip-index"
      // Matches the [1], [2] … numbering of the block the model receives, so a
      // prompt saying "reference 2" lines up with what is on screen.
      num.textContent = `[${i + 1}]`
      chip.appendChild(num)

      const text = document.createElement("span")
      text.className = "supplement-chip-text"
      text.textContent = this.describe(uuid)
      chip.appendChild(text)

      const drop = document.createElement("button")
      drop.type = "button"
      drop.className = "supplement-chip-remove"
      drop.dataset.uuid = uuid
      drop.title = "Stop referencing this node"
      drop.setAttribute("data-action", "click->supplements#remove")
      drop.textContent = "×"
      chip.appendChild(drop)

      this.chipsTarget.appendChild(chip)
    })
  }

  // Read the card's own preview text so a chip is recognisable. Falls back to
  // the uuid when the card is not on screen — which happens if a Turbo Stream
  // replaced the pane while something was selected.
  describe(uuid) {
    const card = this.element.querySelector(`.history-card[data-uuid="${CSS.escape(uuid)}"]`)
    const text = card?.querySelector(".history-card-prompt")?.textContent?.trim()
    return text && text.length > 0 ? text : uuid
  }

  refreshPresets() {
    if (!this.hasPresetsTarget) return
    const empty = !this.hasPromptTarget || this.promptTarget.value.trim().length === 0
    // Only offered into an empty box, so a preset can never overwrite
    // something the user has already written.
    this.presetsTarget.hidden = !(this.selected.length > 0 && empty)
  }
}
