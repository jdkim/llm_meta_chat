module ApplicationHelper
  include LlmMetaClient::Helpers

  MARKDOWN_RENDERER = Redcarpet::Render::HTML.new(
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
    (rendered + block).html_safe
  end
end
