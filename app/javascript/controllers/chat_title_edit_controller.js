import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["link", "display", "input"]
  static values = {
    uuid: String,
    fullTitle: String,
    updateUrl: String
  }

  connect() {
    this._isEditing = false
    this._isSaving = false
    this._originalTitle = this.fullTitleValue
    this.element.addEventListener("dblclick", this._onDblClick.bind(this))
  }

  disconnect() {
    this.element.removeEventListener("dblclick", this._onDblClick.bind(this))
  }

  _onDblClick(event) {
    if (this._isEditing) return
    event.preventDefault()
    event.stopPropagation()
    this._startEditing()
  }

  start() {
    if (this._isEditing) return
    this._startEditing()
  }

  _startEditing() {
    this._isEditing = true
    this._originalTitle = this.fullTitleValue
    this.linkTarget.style.display = "none"
    this.inputTarget.style.display = "block"
    this.inputTarget.value = this.fullTitleValue
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  _stopEditing() {
    this._isEditing = false
    this.inputTarget.style.display = "none"
    this.linkTarget.style.display = ""
  }

  handleKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.inputTarget.blur()
    } else if (event.key === "Escape") {
      event.preventDefault()
      this._cancel()
    }
  }

  save() {
    if (!this._isEditing || this._isSaving) return

    const newTitle = this.inputTarget.value.trim()

    if (newTitle === "" || newTitle === this._originalTitle) {
      this._cancel()
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
      body: JSON.stringify({ title: newTitle })
    })
      .then(response => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then(data => {
        this.fullTitleValue = data.title
        this.displayTarget.textContent = data.truncated_title
        this._stopEditing()
      })
      .catch(error => {
        console.error("Failed to update chat title:", error)
        this._cancel()
      })
      .finally(() => {
        this._isSaving = false
      })
  }

  _cancel() {
    this.inputTarget.value = this._originalTitle
    this._stopEditing()
  }
}
