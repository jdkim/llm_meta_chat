import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="message-stream"
// Opens an EventSource on connect, appends each delta to the content target,
// closes on `done` / `error`.
export default class extends Controller {
  static targets = ["content", "cancelButton"]
  static values = { url: String }

  connect() {
    this.completed = false
    this.cancelled = false
    this.source = new EventSource(this.urlValue)
    this.source.addEventListener("message", (e) => this.#onDelta(e))
    this.source.addEventListener("done", () => this.#onDone())
    this.source.addEventListener("title", (e) => this.#onTitle(e))
    this.source.addEventListener("saved", (e) => this.#onSaved(e))
    this.source.addEventListener("tool_calls", (e) => this.#onToolCalls(e))
    this.source.addEventListener("thinking", (e) => this.#onThinking(e))
    this.source.addEventListener("phase", (e) => this.#onPhase(e))
    this.source.addEventListener("error", (e) => this.#onError(e))
  }

  disconnect() {
    this.#close()
  }

  #onDelta(event) {
    let delta
    try { delta = JSON.parse(event.data).delta } catch { return }
    if (!delta) return
    // First content delta after a "thinking" phase: flip the role label so
    // the user knows generation has actually started.
    this.#exitWorkingPhase()
    this.contentTarget.append(delta)
    this.#scrollToBottom()
  }

  #exitWorkingPhase() {
    const role = this.element.querySelector(".message-role")
    if (role && role.classList.contains("is-working")) {
      role.classList.remove("is-working")
      role.textContent = "🤖 streaming…"
    }
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
      // The saved bubble carries its own (collapsed) Reasoning block, so drop
      // the live one rather than showing two. This is also what makes the
      // reasoning survive a reload: what the user sees from here on is the
      // persisted copy, not the streamed DOM node.
      this.#removeThinkingBlock()
      // Fold the remaining live transient sections now (not on `done`) —
      // `done` fires AFTER the synchronous title-generation round-trip, which
      // can take several seconds and would leave sections open the whole
      // time. Saved is the natural moment: the final message is already
      // persisted and rendered.
      this.#foldTransientSections()
    } catch {}
  }

  // Thinking deltas (Ollama hybrid models with `think: true`, and OpenAI
  // reasoning summaries) — rendered live in a <details> block above the
  // assistant content. This node is transient: on `saved` it is removed and
  // replaced by the persisted Reasoning block inside the saved message, which
  // is what survives a page reload.
  #onThinking(event) {
    let delta
    try { delta = JSON.parse(event.data).delta } catch { return }
    if (!delta) return
    const body = this.#thinkingContentEl()
    body.append(delta)
    // Keep the scroll glued to the bottom of the fixed-height thinking
    // viewport so users see the latest reasoning as it streams.
    body.scrollTop = body.scrollHeight
    this.#scrollToBottom()
  }

  #thinkingContentEl() {
    if (this._thinkingContent) return this._thinkingContent
    const details = document.createElement("details")
    // `thinking-active` triggers the dots animation on the summary while
    // reasoning is in progress; #foldTransientSections drops the class at
    // end-of-stream, and #onSaved removes this node outright. The body is
    // fixed-height + scrollable while open (see chats.css) so a long
    // reasoning trace doesn't dominate the screen even when expanded.
    details.className = "message-thinking thinking-active"
    // Open during streaming; once the message is saved this node goes away
    // and the persisted (collapsed) block takes its place.
    details.open = true
    const summary = document.createElement("summary")
    summary.textContent = "Reasoning"
    // Three staggered-fade dots after "Reasoning". CSS handles the
    // animation; the dots are hidden by default and revealed by the
    // .thinking-active class on the wrapping <details>.
    const dots = document.createElement("span")
    dots.className = "thinking-dots"
    for (let i = 0; i < 3; i += 1) {
      const dot = document.createElement("span")
      dot.textContent = "."
      dots.appendChild(dot)
    }
    summary.appendChild(dots)
    const body = document.createElement("div")
    body.className = "message-thinking-content"
    details.appendChild(summary)
    details.appendChild(body)
    this.contentTarget.parentNode.insertBefore(details, this.contentTarget)
    this._thinkingContent = body
    this._thinkingDetails = details
    return body
  }

  // Collapse the transient streaming-only sections (thinking + live
  // tool-call bubbles) so the assistant's final message gets the focus.
  // Called from #onDone and cancel(); #onSaved goes further and removes both
  // the thinking block and the live tool-call bubbles outright, so this is
  // mostly cosmetic for the no-save (empty content) and cancel paths.
  #foldTransientSections() {
    if (this._thinkingDetails) {
      this._thinkingDetails.open = false
      // Stop the live "thinking…" animation now that streaming has finished.
      this._thinkingDetails.classList.remove("thinking-active")
    }
    document.querySelectorAll(".tool-call-streaming details.tool-calls-section[open]")
      .forEach((d) => { d.open = false })
  }

  #removeThinkingBlock() {
    const el = this._thinkingContent?.parentNode
    if (el && el.parentNode) el.parentNode.removeChild(el)
    this._thinkingContent = null
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

  // Phase events from the server signal what it's currently doing during the
  // synchronous parts of a tool turn (model thinking, tool execution). The role
  // label reflects the phase so users know progress is real, not a hang.
  // The "thinking" phase really means "nothing has come back yet". For a model
  // with think:false there is no reasoning at all — the wait is prefill — so
  // the label says Working, which is true either way. The gear is a separate
  // element so CSS can animate it; the is-working class replaces the old
  // habit of matching on the label text.
  #onPhase(event) {
    let name
    try { name = JSON.parse(event.data).name } catch { return }
    const role = this.element.querySelector(".message-role")
    if (!role) return

    if (name === "thinking") {
      role.innerHTML = '<span class="role-spinner" aria-hidden="true">⚙️</span> Working…'
      role.classList.add("is-working")
    } else if (name === "responding") {
      this.#exitWorkingPhase()
    }
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
    this.#foldTransientSections()
    this.#close()
    // Once the stream is truly done, make the DOM node inert so Turbo's
    // page cache (or a bfcache restore) doesn't re-mount this controller
    // on back-navigation and open a duplicate EventSource against the
    // same execution_id. Without this the server was re-running the
    // whole LLM call on every navigate-back.
    this.element.removeAttribute("data-controller")
    this.element.removeAttribute("data-message-stream-url-value")
  }

  // User clicked the cancel button. Closing the EventSource is enough to
  // cascade cancellation upstream — the host's next stream write will raise
  // ClientDisconnected, propagating cleanly all the way to the provider HTTP
  // socket. The host's controller persists whatever partial content was
  // forwarded so the bubble's content matches what's saved on reload.
  cancel() {
    if (this.completed || this.cancelled) return
    this.cancelled = true
    const role = this.element.querySelector(".message-role")
    if (role) role.textContent = "🚫 cancelled"
    this.element.classList.remove("streaming")
    this.element.classList.add("cancelled")
    if (this.hasCancelButtonTarget) this.cancelButtonTarget.remove()
    this.#foldTransientSections()
    this.#close()
  }

  #onError(event) {
    // EventSource fires onerror whenever the connection closes — including
    // immediately after a clean `event: done` or a user-initiated cancel.
    // Suppress those.
    if (this.completed || this.cancelled) {
      this.#close()
      return
    }
    let message = "Stream interrupted."
    let code = null
    try {
      const parsed = event.data ? JSON.parse(event.data) : {}
      message = parsed.message || message
      code = parsed.code || null
    } catch {}

    // Prefix + role-label pair per error code from the hub's SSE `event: error`
    // shape. Keeps the message text as-is (server owns wording) but adds a
    // tight visual label so users don't have to parse the whole sentence to
    // know what kind of failure it was.
    const codeUX = {
      mcp_unavailable:    { label: "⚠️ MCP tool unavailable", prefix: "MCP tool unavailable" },
      mcp_protocol_error: { label: "⚠️ MCP protocol error",   prefix: "MCP protocol error" },
      timeout:            { label: "⚠️ Upstream timeout",     prefix: "Upstream timeout" },
      rate_limit:         { label: "⚠️ Rate limited",         prefix: "Rate limited" },
      api_key_required:   { label: "⚠️ API key required",     prefix: "API key required" },
      argument_error:     { label: "⚠️ Bad request",          prefix: "Bad request" },
      model_not_found:    { label: "⚠️ Model not found",      prefix: "Model not found" },
      context_overflow:   { label: "⚠️ Context full",         prefix: "Context full" },
    }[code] || { label: "⚠️ error", prefix: "error" }

    // Swap the transient phase label ("⚙️ Working…" / "🤖 streaming…") for
    // a clear failure indicator so the bubble doesn't sit forever pretending
    // to be in flight — this used to leave users staring at a spinning
    // reasoning block when the upstream provider returned e.g. HTTP 503.
    const role = this.element.querySelector(".message-role")
    if (role) {
      role.classList.remove("is-working")
      role.textContent = codeUX.label
    }
    this.element.classList.add("stream-errored")

    // Fold the pulsing "reasoning" section (it stops the animation and
    // collapses the details) and drop any transient tool-call bubbles so
    // nothing looks mid-stream after the error is displayed.
    this.#foldTransientSections()
    this.#removeTransientToolCallBubbles()

    const errEl = document.createElement("p")
    errEl.className = "stream-error"
    errEl.textContent = `[${codeUX.prefix}] ${message}`
    this.contentTarget.appendChild(errEl)
    this.#close()
    // Make the DOM node inert (parallel to #onDone) so Turbo's page cache
    // can't re-mount this controller and open a duplicate stream on
    // back-navigation.
    this.element.removeAttribute("data-controller")
    this.element.removeAttribute("data-message-stream-url-value")
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
