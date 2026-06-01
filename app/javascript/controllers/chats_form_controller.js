import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="chats-form"
export default class extends Controller {
  static targets = [
    "text", "prompt", "submit",
    "imageInput", "imagePreview", "imageThumbnail", "attachButton"
  ]

  connect() {
    this.updateSubmitButton()
    this.updateAttachButton()
    this.#restoreStashedPrompt()
  }

  // Pulls any prompt that was stashed by reauth_banner_controller before
  // bouncing through Google sign-in. One-shot: cleared after restore so
  // a follow-up sign-in doesn't keep re-hydrating stale text.
  #restoreStashedPrompt() {
    if (!this.hasPromptTarget) return
    try {
      const raw = localStorage.getItem("llmMetaPromptStash:v1")
      if (!raw) return
      const stash = JSON.parse(raw)
      // Ignore stashes older than 10 minutes — beyond that the user
      // likely abandoned the flow.
      const STALE_MS = 10 * 60 * 1000
      if (!stash || !stash.prompt || (stash.savedAt && Date.now() - stash.savedAt > STALE_MS)) {
        localStorage.removeItem("llmMetaPromptStash:v1")
        return
      }
      // Don't trample whatever the user has already typed on this page.
      if (this.promptTarget.value && this.promptTarget.value.trim().length > 0) return
      this.promptTarget.value = stash.prompt
      this.updateSubmitButton()
    } catch { /* malformed stash — ignore */ }
    finally {
      localStorage.removeItem("llmMetaPromptStash:v1")
    }
  }

  updateSubmitButton() {
    this.submitTarget.disabled = !this.#canSubmit()
    this.updateAttachButton()
  }

  // Disable the attach button when the selected model isn't vision-capable.
  // model-picker stamps data-supports-vision on the hidden #model input
  // whenever the user picks a model.
  updateAttachButton() {
    if (!this.hasAttachButtonTarget) return
    const supports = this.#selectedModelSupportsVision()
    this.attachButtonTarget.disabled = !supports
    this.attachButtonTarget.title = supports ? "Attach image" : "Selected model doesn't support images"
    if (!supports && this.hasImageInputTarget && this.imageInputTarget.value) {
      // Clear any previously attached image when switching to a text-only model.
      this.clearImage()
    }
  }

  openImagePicker() {
    if (!this.hasImageInputTarget) return
    if (this.hasAttachButtonTarget && this.attachButtonTarget.disabled) return
    this.imageInputTarget.click()
  }

  onImageSelected() {
    if (!this.hasImageInputTarget) return
    const file = this.imageInputTarget.files && this.imageInputTarget.files[0]
    if (!file) return
    if (!this.hasImageThumbnailTarget || !this.hasImagePreviewTarget) return
    const reader = new FileReader()
    reader.onload = (e) => {
      this.imageThumbnailTarget.src = e.target.result
      this.imagePreviewTarget.style.display = ""
    }
    reader.readAsDataURL(file)
  }

  // Drag-and-drop image attachment over the chat form.
  onDragOver(event) {
    if (!this.#dragHasImage(event)) return
    event.preventDefault() // required to allow drop
    if (this.hasAttachButtonTarget && this.attachButtonTarget.disabled) return
    this.element.classList.add("drag-over")
  }

  onDragLeave(event) {
    // dragleave fires when crossing into child nodes too; only clear when
    // we're actually leaving the form root.
    if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
    this.element.classList.remove("drag-over")
  }

  onDrop(event) {
    if (!this.#dragHasImage(event)) return
    event.preventDefault()
    this.element.classList.remove("drag-over")
    if (this.hasAttachButtonTarget && this.attachButtonTarget.disabled) return
    const file = Array.from(event.dataTransfer.files || []).find((f) => f.type.startsWith("image/"))
    if (!file || !this.hasImageInputTarget) return
    // Populate the hidden file input via DataTransfer so the multipart form
    // submit picks it up just like a click-selected file.
    const dt = new DataTransfer()
    dt.items.add(file)
    this.imageInputTarget.files = dt.files
    this.onImageSelected()
  }

  #dragHasImage(event) {
    const items = event.dataTransfer && event.dataTransfer.items
    if (!items) return false
    return Array.from(items).some((it) => it.kind === "file" && it.type.startsWith("image/"))
  }

  // Paste-to-attach: screenshots and copied images dropped onto the
  // prompt textarea get routed through the same multipart upload path
  // as the file picker and drag-drop. Falls through silently when the
  // selected model isn't vision-capable.
  onPaste(event) {
    const items = event.clipboardData && event.clipboardData.items
    if (!items) return
    const imageItem = Array.from(items).find(
      (it) => it.kind === "file" && it.type.startsWith("image/")
    )
    if (!imageItem) return
    if (this.hasAttachButtonTarget && this.attachButtonTarget.disabled) return
    const file = imageItem.getAsFile()
    if (!file || !this.hasImageInputTarget) return
    event.preventDefault()
    const dt = new DataTransfer()
    dt.items.add(file)
    this.imageInputTarget.files = dt.files
    this.onImageSelected()
  }

  clearImage() {
    if (this.hasImageInputTarget) this.imageInputTarget.value = ""
    if (this.hasImageThumbnailTarget) this.imageThumbnailTarget.src = ""
    if (this.hasImagePreviewTarget) this.imagePreviewTarget.style.display = "none"
  }

  #selectedModelSupportsVision() {
    // The grid-view picker writes the chosen model into a hidden input
    // and stamps data-supports-vision on it. Fall back to the legacy
    // <select> shape if the page is still using the old picker.
    const modelInput = document.querySelector('input[name="model"], select[name="model"]')
    if (!modelInput || !modelInput.value) return false
    if (modelInput.tagName === "SELECT") {
      const opt = modelInput.options[modelInput.selectedIndex]
      return opt && opt.dataset.supportsVision === "true"
    }
    return modelInput.dataset.supportsVision === "true"
  }

  // Handle form submission to show user message immediately
  submit(event) {
    // Check generation settings validity before submitting
    const gsController = this.#generationSettingsController()
    if (gsController && !gsController.isValid) {
      event.preventDefault()
      gsController.validate()
      return
    }

    // Don't prevent default - let Turbo handle the form submission
    // Just add the user message to the DOM immediately
    const messageContent = this.promptTarget.value.trim()

    if (!messageContent) {
      return
    }

    // Add user message to the messages list immediately
    this.#addUserMessageToDOM(messageContent)

    // DON'T clear the input here - let the server response handle it
    // Otherwise the POST will be sent with empty value

    // Scroll to bottom
    this.#scrollToBottom()
  }

  #addUserMessageToDOM(content) {
    const messagesList = document.getElementById('messages-list')
    if (!messagesList) return

    // Create message HTML
    const messageDiv = document.createElement('div')
    messageDiv.className = 'message user'
    messageDiv.innerHTML = `
      <div class="message-role">
        👤 You
      </div>
      <div class="message-content">
        <p>${this.#escapeHtml(content)}</p>
      </div>
    `

    messagesList.appendChild(messageDiv)
  }

  #escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  #scrollToBottom() {
    const chatMessages = document.getElementById('chat-messages')
    if (chatMessages) {
      chatMessages.scrollTop = chatMessages.scrollHeight
    }
  }

  #generationSettingsController() {
    const el = this.element.querySelector('[data-controller*="generation-settings"]')
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "generation-settings")
  }

  #canSubmit() {
    // Text field and prompt field can be validated using HTML5's required attribute,
    // so we delegate to checkValidity() to utilize standard validation
    const textField = this.hasTextTarget ? this.textTarget : null
    const promptField = this.promptTarget

    // Use HTML5 standard validation
    const basicFieldsValid =
      (!textField || textField.checkValidity()) && promptField.checkValidity()

    const isGuest = this.element.dataset.guest === "true"

    if (isGuest) {
      return basicFieldsValid
    }

    // Family, API key, and model come from the grid picker as hidden inputs
    // (legacy <select> shape is also tolerated for the old picker).
    const familyInput = document.querySelector('[name="family"]')
    const apiKeyInput = document.querySelector('[name="api_key_uuid"]')
    const modelInput = document.querySelector('[name="model"]')

    const familySelected = !!familyInput?.value
    const apiKeySelected = !!apiKeyInput?.value
    const modelSelected = !!modelInput?.value && !modelInput.disabled

    return basicFieldsValid && familySelected && apiKeySelected && modelSelected
  }
}
