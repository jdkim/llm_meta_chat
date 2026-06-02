import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cards", "checkbox", "selectAll", "heading", "bar", "selectedCount"]
  static values = {
    batchDeletePath: String,
    batchDownloadCsvPath: String
  }

  connect() {
    this.lastIndex = null
    this.#refresh()
    this.#scrollActiveIntoView()
  }

  // When the sidebar re-renders on chat navigation, the active card may
  // be far below the visible scroll viewport. Center it vertically so
  // the user can see surrounding chats too — `block: "nearest"` would
  // park it at the bottom edge, which makes orientation harder. The
  // browser clamps to the scrollable extent, so cards near the top
  // simply land at the top instead of being forced down. "instant"
  // avoids a jarring scroll animation on every page load.
  #scrollActiveIntoView() {
    const active = this.element.querySelector(".chat-card.is-active")
    if (!active) return
    active.scrollIntoView({ block: "center", behavior: "instant" })
  }

  toggle(event) {
    const cb = event.target
    const idx = this.checkboxTargets.indexOf(cb)

    if (event.shiftKey && this.lastIndex !== null && this.lastIndex !== idx) {
      const [a, b] = [this.lastIndex, idx].sort((x, y) => x - y)
      for (let i = a; i <= b; i++) {
        this.checkboxTargets[i].checked = cb.checked
      }
    }

    this.lastIndex = idx
    this.#refresh()
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.checkboxTargets.forEach((cb) => { cb.checked = checked })
    this.lastIndex = null
    this.#refresh()
  }

  bulkDelete(event) {
    event.preventDefault()
    const uuids = this.#selectedUuids()
    if (uuids.length === 0) return
    if (!confirm(`Delete ${uuids.length} chat${uuids.length === 1 ? "" : "s"}? This cannot be undone.`)) return

    this.#submitForm(this.batchDeletePathValue, "delete", uuids)
  }

  bulkDownload(event) {
    event.preventDefault()
    const uuids = this.#selectedUuids()
    if (uuids.length === 0) return

    this.#submitForm(this.batchDownloadCsvPathValue, "post", uuids, { turbo: false })
  }

  #submitForm(action, method, uuids, opts = {}) {
    const form = document.createElement("form")
    form.method = "POST"
    form.action = action
    form.style.display = "none"
    if (opts.turbo === false) form.setAttribute("data-turbo", "false")

    if (method !== "post") {
      const m = document.createElement("input")
      m.type = "hidden"; m.name = "_method"; m.value = method
      form.appendChild(m)
    }

    const csrf = document.querySelector("meta[name=csrf-token]")?.content
    if (csrf) {
      const t = document.createElement("input")
      t.type = "hidden"; t.name = "authenticity_token"; t.value = csrf
      form.appendChild(t)
    }

    uuids.forEach((uuid) => {
      const i = document.createElement("input")
      i.type = "hidden"; i.name = "uuids[]"; i.value = uuid
      form.appendChild(i)
    })

    document.body.appendChild(form)
    form.requestSubmit ? form.requestSubmit() : form.submit()
  }

  #selectedUuids() {
    return this.checkboxTargets.filter((cb) => cb.checked).map((cb) => cb.dataset.uuid)
  }

  #refresh() {
    const total = this.checkboxTargets.length
    const selected = this.checkboxTargets.filter((cb) => cb.checked)
    const count = selected.length

    selected.forEach((cb) => cb.closest(".chat-card")?.classList.add("is-selected"))
    this.checkboxTargets.filter((cb) => !cb.checked).forEach((cb) =>
      cb.closest(".chat-card")?.classList.remove("is-selected")
    )

    if (count > 0) {
      this.headingTarget.classList.add("hidden")
      this.barTarget.classList.remove("hidden")
      if (this.hasSelectedCountTarget) this.selectedCountTarget.textContent = count
    } else {
      this.headingTarget.classList.remove("hidden")
      this.barTarget.classList.add("hidden")
    }

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = count === total && total > 0
      this.selectAllTarget.indeterminate = count > 0 && count < total
    }
  }
}
