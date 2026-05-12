import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    const willOpen = !this.menuTarget.classList.contains("open")
    document.querySelectorAll(".chat-card-menu.open").forEach((m) => m.classList.remove("open"))
    if (willOpen) {
      this.menuTarget.classList.add("open")
      document.addEventListener("click", this._onDocClick, { capture: true })
      document.addEventListener("keydown", this._onKeydown)
    }
  }

  _onDocClick = (event) => {
    if (!this.element.contains(event.target)) {
      this._close()
    }
  }

  _onKeydown = (event) => {
    if (event.key === "Escape") this._close()
  }

  close() {
    this._close()
  }

  _close() {
    this.menuTarget.classList.remove("open")
    document.removeEventListener("click", this._onDocClick, { capture: true })
    document.removeEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick, { capture: true })
    document.removeEventListener("keydown", this._onKeydown)
  }
}
