import { Controller } from "@hotwired/stimulus"

// Inline editor for a chat's note, shown at the top of the History pane.
//
// Modelled on chat_title_edit_controller, with two deliberate differences: the
// editor opens from a visible button rather than a double-click (a note is used
// far less often than a title, so the gesture has to be discoverable), and an
// empty value is a valid save that clears the note rather than a cancel.
export default class extends Controller {
  static targets = ["view", "display", "editor", "input", "editButton"]
  static values = { updateUrl: String }

  connect() {
    this._isSaving = false
    this._original = this.hasDisplayTarget && !this.displayTarget.classList.contains("is-empty")
      ? this.displayTarget.textContent
      : ""
  }

  start() {
    if (!this.hasEditorTarget) return
    this.inputTarget.value = this._original
    this.viewTarget.hidden = true
    this.editorTarget.hidden = false
    this.inputTarget.focus()
  }

  cancel() {
    if (!this.hasEditorTarget) return
    this.editorTarget.hidden = true
    this.viewTarget.hidden = false
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    } else if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.save()
    }
  }

  save() {
    if (this._isSaving || !this.updateUrlValue) return

    const note = this.inputTarget.value.trim()
    if (note === this._original) {
      this.cancel()
      return
    }

    this._isSaving = true
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(this.updateUrlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ note: note })
    })
      .then(response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then(data => {
        this._original = data.note
        this.#render(data.note)
        this.cancel()
      })
      .catch(error => {
        console.error("Failed to update chat note:", error)
        this.cancel()
      })
      .finally(() => {
        this._isSaving = false
      })
  }

  // textContent, not innerHTML: a note is user-entered text and must never be
  // interpreted as markup on its way back into the pane.
  #render(note) {
    this.displayTarget.textContent = note || "No note yet."
    this.displayTarget.classList.toggle("is-empty", !note)
    if (this.hasEditButtonTarget) {
      this.editButtonTarget.textContent = note ? "Edit note" : "+ Add a note"
    }
  }
}
