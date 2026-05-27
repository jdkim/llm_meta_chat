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
  }

  updateSubmitButton() {
    this.submitTarget.disabled = !this.#canSubmit()
    this.updateAttachButton()
  }

  // Disable the attach button when the selected model isn't vision-capable.
  // The signal comes from the model <option>'s data-supports-vision attribute,
  // populated by llm-selector from the server's available_models payload.
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

  clearImage() {
    if (this.hasImageInputTarget) this.imageInputTarget.value = ""
    if (this.hasImageThumbnailTarget) this.imageThumbnailTarget.src = ""
    if (this.hasImagePreviewTarget) this.imagePreviewTarget.style.display = "none"
  }

  #selectedModelSupportsVision() {
    const modelSelect = document.querySelector('select[name="model"]')
    if (!modelSelect || !modelSelect.value) return false
    const opt = modelSelect.options[modelSelect.selectedIndex]
    return opt && opt.dataset.supportsVision === "true"
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

    // Family, API Key and Model selects require JavaScript validation
    const familySelect = document.querySelector('select[name="family"]')
    const apiKeyInput = document.querySelector('[name="api_key_uuid"]')
    const modelSelect = document.querySelector('select[name="model"]')

    const familySelected = familySelect?.value
    const apiKeySelected = !!apiKeyInput?.value
    const modelSelected = modelSelect?.value && !modelSelect.disabled

    return basicFieldsValid && familySelected && apiKeySelected && modelSelected
  }
}
