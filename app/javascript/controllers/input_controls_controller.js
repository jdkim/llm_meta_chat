import { Controller } from "@hotwired/stimulus"

// Coordinates the LLM / Tools / Settings panels so only one is open at a time.
// Each child controller dispatches an "<identifier>:opened" event when its
// panel opens; this controller closes the other ones. Also closes any open
// panel on outside-click or Escape so the user can quickly return to typing.
const CHILDREN = ["llm-toggle", "tool-selector", "generation-settings"]

export default class extends Controller {
  connect() {
    this._onOpened = (event) => {
      const openedBy = event.target.closest("[data-controller~='" + CHILDREN.join("'], [data-controller~='") + "']")
      if (!openedBy) return
      CHILDREN.forEach((ident) => {
        if (openedBy.matches(`[data-controller~="${ident}"]`)) return
        this.#closeChild(ident)
      })
    }
    CHILDREN.forEach((ident) => {
      this.element.addEventListener(`${ident}:opened`, this._onOpened)
    })

    this._onDocClick = (event) => {
      if (this.element.contains(event.target)) return
      this.#closeAll()
    }
    document.addEventListener("click", this._onDocClick)

    this._onKeydown = (event) => {
      if (event.key === "Escape") this.#closeAll()
    }
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    if (this._onOpened) {
      CHILDREN.forEach((ident) => {
        this.element.removeEventListener(`${ident}:opened`, this._onOpened)
      })
    }
    if (this._onDocClick) document.removeEventListener("click", this._onDocClick)
    if (this._onKeydown) document.removeEventListener("keydown", this._onKeydown)
  }

  #closeChild(ident) {
    const el = this.element.querySelector(`[data-controller~="${ident}"]`)
    if (!el) return
    const ctrl = this.application.getControllerForElementAndIdentifier(el, ident)
    if (ctrl?.expanded) ctrl.toggle()
  }

  #closeAll() {
    CHILDREN.forEach((ident) => this.#closeChild(ident))
  }
}
