import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="message-stream"
// Opens an EventSource on connect, appends each delta to the content target,
// closes on `done` / `error`.
export default class extends Controller {
  static targets = ["content"]
  static values = { url: String }

  connect() {
    this.completed = false
    this.source = new EventSource(this.urlValue)
    this.source.addEventListener("message", (e) => this.#onDelta(e))
    this.source.addEventListener("done", () => this.#onDone())
    this.source.addEventListener("title", (e) => this.#onTitle(e))
    this.source.addEventListener("saved", (e) => this.#onSaved(e))
    this.source.addEventListener("tool_calls", (e) => this.#onToolCalls(e))
    this.source.addEventListener("error", (e) => this.#onError(e))
  }

  disconnect() {
    this.#close()
  }

  #onDelta(event) {
    let delta
    try { delta = JSON.parse(event.data).delta } catch { return }
    if (!delta) return
    this.contentTarget.append(delta)
    this.#scrollToBottom()
  }

  #onTitle(event) {
    try {
      const data = JSON.parse(event.data)
      if (data.turbo_stream && window.Turbo) {
        window.Turbo.renderStreamMessage(data.turbo_stream)
      }
    } catch {}
  }

  #onSaved(event) {
    try {
      const data = JSON.parse(event.data)
      this.element.dataset.savedExecutionId = data.execution_id
      if (data.html) this.#swapInRenderedMessage(data.html)
      // The saved bubble's content already includes any tool calls section in
      // markdown; remove the transient tool-call bubbles so reload and live look
      // the same.
      this.#removeTransientToolCallBubbles()
    } catch {}
  }

  #onToolCalls(event) {
    try {
      const data = JSON.parse(event.data)
      if (!data.html) return
      const wrapper = document.createElement("template")
      wrapper.innerHTML = data.html.trim()
      const bubble = wrapper.content.firstElementChild
      if (!bubble) return
      bubble.classList.add("tool-call-streaming")
      this.element.parentNode.insertBefore(bubble, this.element)
      this.#scrollToBottom()
    } catch {}
  }

  #removeTransientToolCallBubbles() {
    document.querySelectorAll(".tool-call-streaming").forEach((el) => el.remove())
  }

  // Swap the streaming bubble's role + content with the host-rendered _message
  // partial output so any markdown / syntax highlighting / partial customizations
  // applied on reload also apply right after the stream finishes. We don't
  // replace the whole element — that would disconnect this controller and
  // close the EventSource before `title` / `done` arrive.
  #swapInRenderedMessage(html) {
    const doc = new DOMParser().parseFromString(html, "text/html")
    const newBubble = doc.querySelector(".message")
    if (!newBubble) return

    const newRole = newBubble.querySelector(".message-role")
    const oldRole = this.element.querySelector(".message-role")
    if (newRole && oldRole) oldRole.innerHTML = newRole.innerHTML

    const newContent = newBubble.querySelector(".message-content")
    if (newContent) this.contentTarget.innerHTML = newContent.innerHTML

    this.element.classList.remove("streaming")
    if (newBubble.id) this.element.id = newBubble.id
  }

  #onDone() {
    this.completed = true
    this.#close()
  }

  #onError(event) {
    // EventSource fires onerror whenever the connection closes — including
    // immediately after a clean `event: done`. Suppress those.
    if (this.completed) {
      this.#close()
      return
    }
    let message = "Stream interrupted."
    try { if (event.data) message = JSON.parse(event.data).message || message } catch {}
    const errEl = document.createElement("p")
    errEl.className = "stream-error"
    errEl.textContent = `[error] ${message}`
    this.contentTarget.appendChild(errEl)
    this.#close()
  }

  #close() {
    if (this.source && this.source.readyState !== EventSource.CLOSED) {
      this.source.close()
    }
  }

  #scrollToBottom() {
    const chatMessages = document.getElementById("chat-messages")
    if (chatMessages) chatMessages.scrollTop = chatMessages.scrollHeight
  }
}
