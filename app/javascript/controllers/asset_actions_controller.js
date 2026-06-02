import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="asset-actions"
//
// Powers the Download / Copy buttons rendered next to assistant-generated
// assets (images and copyable code blocks — JSON, CSV). Markup is emitted
// by ApplicationHelper::AssistantResponseRenderer.
//
// Values:
//   kindValue       — "image" or "text"; chooses copy/download strategy
//   hrefValue       — for kind=image, the image src (data URL or http)
//   filenameValue   — suggested download filename
//   mimeValue       — for kind=text, the MIME type of the generated Blob
export default class extends Controller {
  static values = {
    kind: { type: String, default: "text" },
    href: { type: String, default: "" },
    filename: { type: String, default: "download" },
    mime: { type: String, default: "text/plain" },
  }

  async download(event) {
    const btn = event.currentTarget
    try {
      if (this.kindValue === "image") {
        this.#triggerDownload(this.hrefValue, this.filenameValue)
      } else {
        const text = this.#extractText()
        const blob = new Blob([text], { type: this.mimeValue })
        const url = URL.createObjectURL(blob)
        this.#triggerDownload(url, this.filenameValue)
        // Yield a tick before revoking so the browser has time to start
        // the download — Blob URLs revoked too eagerly cancel the file.
        setTimeout(() => URL.revokeObjectURL(url), 1000)
      }
      this.#flashOk(btn)
    } catch (e) {
      console.error("[asset-actions] download failed", e)
      this.#flashFail(btn)
    }
  }

  async copyText(event) {
    const btn = event.currentTarget
    try {
      await navigator.clipboard.writeText(this.#extractText())
      this.#flashOk(btn)
    } catch (e) {
      console.error("[asset-actions] copyText failed", e)
      this.#flashFail(btn)
    }
  }

  async copyImage(event) {
    const btn = event.currentTarget
    try {
      const resp = await fetch(this.hrefValue)
      const blob = await resp.blob()
      if (typeof ClipboardItem === "undefined") {
        throw new Error("ClipboardItem unsupported in this browser")
      }
      await navigator.clipboard.write([
        new ClipboardItem({ [blob.type]: blob }),
      ])
      this.#flashOk(btn)
    } catch (e) {
      console.error("[asset-actions] copyImage failed", e)
      this.#flashFail(btn)
    }
  }

  #triggerDownload(href, filename) {
    const a = document.createElement("a")
    a.href = href
    a.download = filename
    document.body.appendChild(a)
    a.click()
    a.remove()
  }

  #extractText() {
    const code = this.element.querySelector("code")
    return (code ? code.textContent : this.element.textContent) || ""
  }

  // Brief icon flip so the user sees the click registered. 1.2s is long
  // enough to read, short enough to not collide with a second click.
  #flashOk(btn)  { this.#flashIcon(btn, "bi-check-lg") }
  #flashFail(btn) { this.#flashIcon(btn, "bi-exclamation-circle") }

  #flashIcon(btn, replacementClass) {
    const icon = btn?.querySelector("i")
    if (!icon) return
    const original = icon.className
    icon.className = `bi ${replacementClass}`
    setTimeout(() => { icon.className = original }, 1200)
  }
}
