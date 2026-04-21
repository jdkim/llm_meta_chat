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
end
