import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="tool-selector"
export default class extends Controller {
  static targets = [
    "toggleButton",
    "toggleIcon",
    "countBadge",
    "panel",
    "loading",
    "serverList",
  ]

  connect() {
    this.mcpServers = []
    this.expanded = false
    this.selectedToolIds = new Set()
    this.#ensureHiddenFields()
  }

  toggle() {
    if (!this.hasPanelTarget) return

    this.expanded = !this.expanded
    this.panelTarget.style.display = this.expanded ? "block" : "none"

    if (this.hasToggleIconTarget) {
      this.toggleIconTarget.classList.toggle("bi-chevron-up", !this.expanded)
      this.toggleIconTarget.classList.toggle("bi-chevron-down", this.expanded)
    }

    if (this.expanded && this.mcpServers.length === 0) {
      this.#fetchMcpServers()
    }

    if (this.expanded) this.dispatch("opened", { bubbles: true })
  }

  toggleServer(event) {
    const serverUuid = event.currentTarget.dataset.serverUuid
    const toolsContainer = this.serverListTarget.querySelector(
      `[data-server-tools="${CSS.escape(serverUuid)}"]`
    )
    const icon = event.currentTarget.querySelector(".server-toggle-icon")

    if (!toolsContainer) return

    const isVisible = toolsContainer.style.display !== "none"
    toolsContainer.style.display = isVisible ? "none" : "block"
    icon.classList.toggle("bi-chevron-right", isVisible)
    icon.classList.toggle("bi-chevron-down", !isVisible)

    // Fetch tools if not yet loaded
    if (
      !isVisible &&
      toolsContainer.dataset.loaded !== "true"
    ) {
      this.#fetchToolsForServer(serverUuid, toolsContainer)
    }
  }

  toggleTool(event) {
    const toolId = event.currentTarget.value
    if (event.currentTarget.checked) {
      this.selectedToolIds.add(toolId)
    } else {
      this.selectedToolIds.delete(toolId)
    }
    this.#updateCountBadge()
    this.#updateHiddenFields()
  }

  async #fetchMcpServers() {
    this.loadingTarget.style.display = "block"
    this.serverListTarget.innerHTML = ""

    try {
      const response = await fetch("/api/mcp_servers", {
        headers: { Accept: "application/json" },
      })

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      const data = await response.json()
      this.mcpServers = data.mcp_servers || []

      if (this.mcpServers.length === 0) {
        this.serverListTarget.innerHTML =
          '<div class="no-servers">No MCP servers available</div>'
      } else {
        this.#renderServerList()
      }
    } catch (e) {
      console.error("Failed to fetch MCP servers:", e)
      this.serverListTarget.innerHTML =
        '<div class="no-servers">Failed to load MCP servers</div>'
    } finally {
      this.loadingTarget.style.display = "none"
    }
  }

  #renderServerList() {
    this.serverListTarget.innerHTML = ""

    for (const server of this.mcpServers) {
      if (!server.active) continue

      const serverDiv = document.createElement("div")
      serverDiv.className = "mcp-server-item"
      const escapedUuid = this.#escapeAttr(server.uuid)
      serverDiv.innerHTML = `
        <div class="mcp-server-header" data-action="click->tool-selector#toggleServer" data-server-uuid="${escapedUuid}">
          <i class="bi bi-chevron-right server-toggle-icon"></i>
          <i class="bi bi-server"></i>
          <span class="mcp-server-name">${this.#escapeHtml(server.name)}</span>
          ${server.tools && server.tools.length > 0 ? `<span class="tool-available-count">${server.tools.filter((t) => t.active).length} tools</span>` : ""}
        </div>
        <div class="mcp-server-tools" data-server-tools="${escapedUuid}" style="display: none;" data-loaded="${server.tools && server.tools.length > 0 ? "true" : "false"}">
          ${server.tools && server.tools.length > 0 ? this.#renderTools(server.tools) : '<div class="tool-loading-inline">Click to load tools...</div>'}
        </div>
      `
      this.serverListTarget.appendChild(serverDiv)
    }
  }

  #renderTools(tools) {
    const activeTools = tools.filter((t) => t.active)
    if (activeTools.length === 0) {
      return '<div class="no-tools">No active tools</div>'
    }

    return activeTools
      .map(
        (tool) => `
      <label class="tool-item">
        <input type="checkbox"
               value="${this.#escapeAttr(String(tool.id))}"
               data-action="change->tool-selector#toggleTool"
               ${this.selectedToolIds.has(String(tool.id)) ? "checked" : ""}>
        <div class="tool-info">
          <span class="tool-name">${this.#escapeHtml(tool.name)}</span>
          ${tool.description ? `<span class="tool-description">${this.#escapeHtml(tool.description)}</span>` : ""}
        </div>
      </label>
    `
      )
      .join("")
  }

  async #fetchToolsForServer(serverUuid, container) {
    container.innerHTML =
      '<div class="tool-loading-inline">Loading tools...</div>'

    try {
      const response = await fetch(
        `/api/mcp_servers/${encodeURIComponent(serverUuid)}/tools`,
        {
          headers: { Accept: "application/json" },
        }
      )

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      const data = await response.json()
      const tools = data.tools || []

      container.dataset.loaded = "true"
      container.innerHTML = this.#renderTools(tools)

      // Update cached server data
      const server = this.mcpServers.find((s) => s.uuid === serverUuid)
      if (server) {
        server.tools = tools
      }
    } catch (e) {
      console.error("Failed to fetch tools:", e)
      container.innerHTML =
        '<div class="no-tools">Failed to load tools</div>'
    }
  }

  #updateCountBadge() {
    const count = this.selectedToolIds.size
    this.countBadgeTarget.textContent = count
    this.countBadgeTarget.style.display = count > 0 ? "inline-block" : "none"
  }

  #ensureHiddenFields() {
    // Container for hidden tool_ids fields
    let container = this.element.querySelector(".tool-ids-hidden-fields")
    if (!container) {
      container = document.createElement("div")
      container.className = "tool-ids-hidden-fields"
      container.style.display = "none"
      this.element.appendChild(container)
    }
  }

  #updateHiddenFields() {
    const container = this.element.querySelector(".tool-ids-hidden-fields")
    if (!container) return

    container.innerHTML = ""
    for (const toolId of this.selectedToolIds) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "tool_ids[]"
      input.value = toolId
      container.appendChild(input)
    }
  }

  #escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  #escapeAttr(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }
}
