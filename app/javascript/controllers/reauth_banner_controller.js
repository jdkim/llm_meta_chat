import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="reauth-banner"
//
// When the user clicks "Sign in again" while in a needs-reauth state,
// stash any unsent prompt-form state in localStorage BEFORE handing off
// to the OAuth round-trip. chats_form_controller restores it on its
// next #connect (which fires when the user lands back on the chat
// composer after authentication completes).
const STASH_KEY = "llmMetaPromptStash:v1"

export default class extends Controller {
  stashAndSubmit(event) {
    // Don't block the form submission — stashing is best-effort.
    try {
      const promptEl = document.getElementById("message-input")
      if (promptEl && promptEl.value && promptEl.value.trim().length > 0) {
        const payload = {
          prompt: promptEl.value,
          savedAt: Date.now(),
          // Best-effort URL hint so we can re-hydrate on the same chat
          // (vs landing back at root_path after sign-in).
          path: window.location.pathname,
        }
        localStorage.setItem(STASH_KEY, JSON.stringify(payload))
      }
    } catch { /* localStorage unavailable / quota — submit anyway */ }
    // Do NOT preventDefault; the form proceeds to /users/auth/google_oauth2.
  }
}
