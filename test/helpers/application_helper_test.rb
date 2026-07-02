require "test_helper"

# Coverage for ApplicationHelper::AssistantResponseRenderer — the custom
# Redcarpet renderer that wraps assistant-emitted images and copyable code
# blocks with Download / Copy action buttons. Regressions here are hard to
# spot in the UI because the markdown still renders fine without the
# wrapper, just without the buttons.
class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "JSON fenced code block gets wrapped with Copy + Download buttons" do
    html = assistant_response_markdown("```json\n{\"a\":1}\n```")
    assert_includes html, "data-controller=\"asset-actions\""
    assert_includes html, "data-asset-actions-kind-value=\"text\""
    assert_includes html, "data-asset-actions-filename-value=\"response.json\""
    assert_includes html, "data-asset-actions-mime-value=\"application/json\""
    assert_includes html, "asset-actions#copyText"
    assert_includes html, "asset-actions#download"
    # Code content is preserved inside <code> for the JS to extract.
    assert_includes html, "&quot;a&quot;:1"
  end

  test "CSV fenced code block gets wrapped" do
    html = assistant_response_markdown("```csv\na,b\n1,2\n```")
    assert_includes html, "response-asset-code"
    assert_includes html, "data-asset-actions-filename-value=\"response.csv\""
    assert_includes html, "data-asset-actions-mime-value=\"text/csv\""
  end

  test "non-copyable code blocks (ruby, etc.) fall through untouched" do
    html = assistant_response_markdown("```ruby\nputs :hi\n```")
    refute_includes html, "response-asset"
    refute_includes html, "asset-actions"
    # Plain Redcarpet output retains the <code> tag.
    assert_includes html, "<code"
  end

  test "data: URL image gets wrapped with Download + Copy, filename derived from MIME" do
    html = assistant_response_markdown("![](data:image/png;base64,AAA)")
    assert_includes html, "response-asset-image"
    assert_includes html, "data-asset-actions-kind-value=\"image\""
    assert_includes html, "data-asset-actions-filename-value=\"image.png\""
    assert_includes html, "asset-actions#copyImage"
    assert_includes html, "asset-actions#download"
  end

  test "JPEG data URL produces image.jpeg filename" do
    html = assistant_response_markdown("![](data:image/jpeg;base64,BBB)")
    assert_includes html, "data-asset-actions-filename-value=\"image.jpeg\""
  end

  test "HTTP image URL preserves the basename for download" do
    html = assistant_response_markdown("![](https://example.com/path/cat.png)")
    assert_includes html, "data-asset-actions-filename-value=\"cat.png\""
  end

  test "trailing tool-calls section is still folded into <details> when buttons are involved" do
    response = <<~MD
      ```json
      {"ok":true}
      ```

      ---

      **Tool calls**

      - `weather`
    MD
    html = assistant_response_markdown(response)
    assert_includes html, "response-asset-code"
    assert_includes html, "tool-calls-section"
    assert_includes html, "<summary"
  end

  test "tool-calls section renders before the main response body" do
    response = <<~MD
      main response goes here

      ---

      **Tool calls**

      - `weather`
    MD
    html = assistant_response_markdown(response)
    tool_calls_idx = html.index("tool-calls-section")
    body_idx = html.index("main response goes here")
    assert tool_calls_idx, "expected tool-calls-section in output"
    assert body_idx, "expected main body in output"
    assert tool_calls_idx < body_idx, "expected tool-calls-section to appear before the main body"
  end

  test "non-markdown plain text still renders without wrapping" do
    html = assistant_response_markdown("just a sentence")
    refute_includes html, "response-asset"
    assert_includes html, "just a sentence"
  end
end
