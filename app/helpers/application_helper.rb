module ApplicationHelper
  include LlmMetaClient::Helpers

  # Subclass of Redcarpet's HTML renderer that wraps assistant-generated
  # images and copyable code blocks (`json`, `csv`) in a `.response-asset`
  # container with Download / Copy action buttons. The buttons are powered
  # client-side by `asset_actions_controller`. Anything else falls through
  # to the default renderer.
  class AssistantResponseRenderer < Redcarpet::Render::HTML
    COPYABLE_LANGUAGES = %w[json csv].freeze

    # Note on `super`: Redcarpet's default HTML renderer methods are
    # implemented in C, so calling `super` raises NoMethodError. For the
    # fall-through case in block_code, and for the image markup, we emit
    # the equivalent HTML directly.
    # `image` is INLINE-level in Redcarpet's grammar, so any newline in our
    # return value gets converted to a literal `<br>` by `hard_wrap: true`
    # and breaks the wrapper's opening tag. Keep the whole thing on one
    # line — multi-line HTML is fine for the block-level `block_code`
    # below, but never here.
    def image(link, title, alt_text)
      filename = derive_image_filename(link)
      esc_link = ERB::Util.html_escape(link)
      esc_alt  = ERB::Util.html_escape(alt_text.to_s)
      esc_filename = ERB::Util.html_escape(filename)
      esc_title = title.present? ? %( title="#{ERB::Util.html_escape(title)}") : ""
      img_tag = %(<img src="#{esc_link}" alt="#{esc_alt}"#{esc_title}>)
      # Use spans throughout the inline image wrapper so we don't nest a
      # `<div>` inside a `<span>` (invalid HTML; some browsers force-close
      # the span). `.asset-actions` styles work on either element type.
      actions = %(<span class="asset-actions">) +
                %(<button type="button" class="asset-action" title="Download" data-action="click->asset-actions#download"><i class="bi bi-download"></i></button>) +
                %(<button type="button" class="asset-action" title="Copy image" data-action="click->asset-actions#copyImage"><i class="bi bi-clipboard"></i></button>) +
                %(</span>)
      %(<span class="response-asset response-asset-image" data-controller="asset-actions" data-asset-actions-kind-value="image" data-asset-actions-href-value="#{esc_link}" data-asset-actions-filename-value="#{esc_filename}">#{img_tag}#{actions}</span>)
    end

    def block_code(code, language)
      lang = language.to_s.downcase
      escaped = ERB::Util.html_escape(code)
      unless COPYABLE_LANGUAGES.include?(lang)
        # Mimic Redcarpet's default fenced-code output: <pre><code class="lang">…</code></pre>
        lang_class = lang.empty? ? "" : %( class="#{ERB::Util.html_escape(lang)}")
        return %(<pre><code#{lang_class}>#{escaped}</code></pre>\n)
      end

      ext = lang
      mime = mime_for(lang)
      <<~HTML
        <div class="response-asset response-asset-code"
             data-controller="asset-actions"
             data-asset-actions-kind-value="text"
             data-asset-actions-filename-value="response.#{ext}"
             data-asset-actions-mime-value="#{mime}">
          <pre><code class="language-#{lang}">#{escaped}</code></pre>
          <div class="asset-actions">
            <button type="button" class="asset-action" title="Copy" data-action="click->asset-actions#copyText">
              <i class="bi bi-clipboard"></i>
            </button>
            <button type="button" class="asset-action" title="Download" data-action="click->asset-actions#download">
              <i class="bi bi-download"></i>
            </button>
          </div>
        </div>
      HTML
    end

    private

    def derive_image_filename(link)
      if link.to_s.start_with?("data:")
        mime = link[/\Adata:([^;]+);/, 1].to_s
        ext = mime.split("/").last.to_s.split(/[;+]/).first
        ext = "png" if ext.empty?
        "image.#{ext}"
      else
        File.basename(link.to_s.split("?").first.to_s).presence || "image"
      end
    end

    def mime_for(language)
      case language
      when "json" then "application/json"
      when "csv"  then "text/csv"
      else "text/plain"
      end
    end
  end

  MARKDOWN_RENDERER = AssistantResponseRenderer.new(
    escape_html: true,
    hard_wrap: true,
    link_attributes: { target: "_blank", rel: "noopener noreferrer" }
  )

  MARKDOWN = Redcarpet::Markdown.new(
    MARKDOWN_RENDERER,
    autolink: true,
    fenced_code_blocks: true,
    tables: true,
    strikethrough: true,
    superscript: true,
    no_intra_emphasis: true,
    space_after_headers: true
  )

  def markdown(text)
    return "" if text.blank?
    MARKDOWN.render(text.to_s).html_safe
  end

  # Pull a leading `[filename](data:mime;base64,DATA)` document attachment
  # off a user prompt so it can be rendered as a download chip while the
  # remaining text renders plain. Returns [chip_html_safe_or_nil, remaining_text].
  # Distinct from split_attached_image_html by the absence of the leading `!`.
  ATTACHED_DOCUMENT_HEAD = /\A\[([^\]]*)\]\(data:([^;]+);base64,([^\)]+)\)\s*\n*/m

  def split_attached_document_html(text)
    s = text.to_s
    m = s.match(ATTACHED_DOCUMENT_HEAD)
    return [ nil, s ] unless m
    filename = m[1].presence || "attachment"
    href     = "data:#{m[2]};base64,#{m[3]}"
    chip = tag.a(
      "📄 #{filename}",
      href: href,
      download: filename,
      class: "user-attached-document",
      rel: "noopener"
    )
    [ chip, s.sub(ATTACHED_DOCUMENT_HEAD, "") ]
  end

  # Render an assistant response, wrapping any trailing "**Tool calls**"
  # section in a collapsed <details> block. The marker is the literal
  # `\n\n---\n\n**Tool calls**` separator that llm_meta_client appends in
  # ServerQuery#combine_with_tool_calls.
  TOOL_CALLS_SPLIT = /\n\n---\n\n(?=\*\*Tool calls\*\*)/m

  def assistant_response_markdown(text)
    return "" if text.blank?
    head, tools = text.to_s.split(TOOL_CALLS_SPLIT, 2)
    rendered = markdown(head)
    return rendered unless tools

    # Strip the literal "**Tool calls**" heading from the tools section —
    # the <summary> below serves as the heading instead.
    tools_body = tools.sub(/\A\*\*Tool calls\*\*\n+/, "")
    summary = content_tag(:summary, "🛠 Tool calls")
    block = content_tag(:details, summary + markdown(tools_body), class: "tool-calls-section")
    # Tool calls go first so the user sees what the model did before the
    # narrative response. During live streaming, tool call bubbles appear
    # above the assistant bubble; showing the section on top after persist
    # keeps the visual position consistent.
    (block + rendered).html_safe
  end
end
