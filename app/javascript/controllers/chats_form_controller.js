import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="chats-form"
export default class extends Controller {
  static targets = ["text", "prompt", "submit"]

  connect() {
    this.updateSubmitButton()
  }

  updateSubmitButton() {
    this.submitTarget.disabled = !this.#canSubmit()
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
