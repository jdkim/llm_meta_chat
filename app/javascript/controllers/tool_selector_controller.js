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
    // Refresh the parent server's "select all" checkbox state so it
    // reflects the mix of checked/unchecked child tools.
    const container = event.currentTarget.closest("[data-server-tools]")
    const serverUuid = container?.getAttribute("data-server-tools")
    if (serverUuid) this.#updateServerHeaderCheckbox(serverUuid)
  }

  // Select / deselect every active tool for the given server.
  toggleAllForServer(event) {
    const checkbox = event.currentTarget
    const serverUuid = checkbox.dataset.serverUuid
    const shouldSelect = checkbox.checked
    const container = this.serverListTarget.querySelector(
      `[data-server-tools="${CSS.escape(serverUuid)}"]`
    )
    if (!container) return

    // If tools haven't been fetched yet, kick off the fetch, then re-apply
    // the toggle once they land. Fresh servers show a "Click to load tools…"
    // placeholder — the user's intent is clearly to grab everything the
    // server has, so lazy-load transparently.
    if (container.dataset.loaded !== "true") {
      this.#fetchToolsForServer(serverUuid, container).then(() => {
        this.#applyServerBulkToggle(serverUuid, container, shouldSelect)
      })
    } else {
      this.#applyServerBulkToggle(serverUuid, container, shouldSelect)
    }
  }

  // Prevent a click on the select-all checkbox from bubbling up to the
  // server-header row (which handles expand/collapse). Without this, ticking
  // the box would also close/open the panel unexpectedly.
  stopBubble(event) {
    event.stopPropagation()
  }

  #applyServerBulkToggle(serverUuid, container, shouldSelect) {
    const checkboxes = container.querySelectorAll('input[type="checkbox"]')
    checkboxes.forEach((cb) => {
      cb.checked = shouldSelect
      const toolId = cb.value
      if (shouldSelect) {
        this.selectedToolIds.add(toolId)
      } else {
        this.selectedToolIds.delete(toolId)
      }
    })
    this.#updateCountBadge()
    this.#updateHiddenFields()
    this.#updateServerHeaderCheckbox(serverUuid)
  }

  // Reflect the current selection state on the server-header "select all"
  // checkbox: checked when every active tool is selected, unchecked when
  // none are, indeterminate for a mix.
  #updateServerHeaderCheckbox(serverUuid) {
    const header = this.serverListTarget.querySelector(
      `.mcp-server-select-all[data-server-uuid="${CSS.escape(serverUuid)}"]`
    )
    const container = this.serverListTarget.querySelector(
      `[data-server-tools="${CSS.escape(serverUuid)}"]`
    )
    if (!header || !container) return

    const checkboxes = Array.from(container.querySelectorAll('input[type="checkbox"]'))
    if (checkboxes.length === 0) {
      header.checked = false
      header.indeterminate = false
      header.disabled = true
      return
    }
    header.disabled = false
    const selected = checkboxes.filter((cb) => cb.checked).length
    if (selected === 0) {
      header.checked = false
      header.indeterminate = false
    } else if (selected === checkboxes.length) {
      header.checked = true
      header.indeterminate = false
    } else {
      header.checked = false
      header.indeterminate = true
    }
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
      const sharedBadge = server.owned === false
        ? `<span class="mcp-server-shared-badge" title="Shared by ${this.#escapeAttr(server.shared_by || "another user")} — verify before enabling tools you don't trust">
             <i class="bi bi-people-fill"></i> ${this.#escapeHtml(server.shared_by || "shared")}
           </span>`
        : ""
      serverDiv.innerHTML = `
        <div class="mcp-server-header" data-action="click->tool-selector#toggleServer" data-server-uuid="${escapedUuid}">
          <i class="bi bi-chevron-right server-toggle-icon"></i>
          <i class="bi bi-server"></i>
          <span class="mcp-server-name">${this.#escapeHtml(server.name)}</span>
          ${server.tools && server.tools.length > 0 ? `<span class="tool-available-count">${server.tools.filter((t) => t.active).length} tools</span>` : ""}
          ${sharedBadge}
          <input type="checkbox" class="mcp-server-select-all"
                 data-server-uuid="${escapedUuid}"
                 data-action="change->tool-selector#toggleAllForServer click->tool-selector#stopBubble"
                 title="Select / deselect all tools in this server">
        </div>
        <div class="mcp-server-tools" data-server-tools="${escapedUuid}" style="display: none;" data-loaded="${server.tools && server.tools.length > 0 ? "true" : "false"}">
          ${server.tools && server.tools.length > 0 ? this.#renderTools(server.tools) : '<div class="tool-loading-inline">Click to load tools...</div>'}
        </div>
      `
      this.serverListTarget.appendChild(serverDiv)
      if (server.tools && server.tools.length > 0) {
        this.#updateServerHeaderCheckbox(server.uuid)
      }
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
          <span class="tool-name-row">
            <span class="tool-name">${this.#escapeHtml(tool.name)}</span>${this.#renderToolBadges(tool)}
          </span>
          ${tool.description ? `<span class="tool-description">${this.#escapeHtml(tool.description)}</span>` : ""}
        </div>
      </label>
    `
      )
      .join("")
  }

  // MCP 2025-03-26 tool annotations — same semantics as the server-side
  // pane badges. Only render a badge when the hint is explicitly true;
  // missing/false = "no claim", not shown.
  #renderToolBadges(tool) {
    const a = tool.annotations || {}
    let out = ""
    if (a.readOnlyHint === true)    out += ' <span class="tool-badge tool-badge-readonly"    title="Server declared this tool does not modify its environment">Read-only</span>'
    if (a.destructiveHint === true) out += ' <span class="tool-badge tool-badge-destructive" title="Server declared this tool may perform destructive updates">Destructive</span>'
    if (a.idempotentHint === true)  out += ' <span class="tool-badge tool-badge-idempotent"  title="Server declared repeated calls have the same effect as a single call">Idempotent</span>'
    if (a.openWorldHint === true)   out += ' <span class="tool-badge tool-badge-openworld"   title="Server declared this tool interacts with external services (open world)">Open-world</span>'
    return out
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
      // Sync the header "select all" checkbox to the freshly-loaded tools —
      // handles the case where the user had previous selections restored.
      this.#updateServerHeaderCheckbox(serverUuid)
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
