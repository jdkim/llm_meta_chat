require "test_helper"

# Tests for the document-attachment upload path in ChatsController.
# Covers uploaded_document_payload's MIME/size gating (the controller is
# the only gate — the model doesn't re-validate what the type is).
class ChatsControllerUploadTest < ActionDispatch::IntegrationTest
  setup do
    # No LLM catalog needed for the create path itself; stub the resource
    # calls that render the picker on chat pages so this test doesn't
    # reach out over HTTP.
    LlmMetaClient::ServerResource.singleton_class.send(:alias_method, :__orig_available_llm_families, :available_llm_families) rescue nil
    LlmMetaClient::ServerResource.singleton_class.send(:define_method, :available_llm_families) { |*| [] }
  end

  teardown do
    if LlmMetaClient::ServerResource.singleton_class.method_defined?(:__orig_available_llm_families)
      LlmMetaClient::ServerResource.singleton_class.send(:alias_method, :available_llm_families, :__orig_available_llm_families)
    end
  end

  test "POST /chats with a text/markdown document stores it as a data-URI link at the head of the prompt" do
    assert_difference -> { PromptNavigator::PromptExecution.count }, 1 do
      post chats_path, params: {
        message: "please summarize",
        document: fixture_file_upload("notes.md", "text/markdown")
      }
    end
    pe = PromptNavigator::PromptExecution.order(:id).last
    assert_match(/\A\[notes\.md\]\(data:text\/markdown;base64,[^\)]+\)\s+please summarize/, pe.prompt)
  end

  test "POST /chats with a non-text mime type (image/png) uploaded as document is rejected" do
    assert_difference -> { PromptNavigator::PromptExecution.count }, 1 do
      post chats_path, params: {
        message: "attempt image as doc",
        document: fixture_file_upload("tiny.png", "image/png")
      }
    end
    pe = PromptNavigator::PromptExecution.order(:id).last
    # Doc rejected → prompt is just the user message, no data-URI prefix.
    assert_equal "attempt image as doc", pe.prompt
  end

  test "POST /chats with an oversized document (>1MB) is rejected" do
    big = Tempfile.new([ "big", ".txt" ])
    big.write("x" * (2 * 1024 * 1024))
    big.rewind
    assert_difference -> { PromptNavigator::PromptExecution.count }, 1 do
      post chats_path, params: {
        message: "too big",
        document: Rack::Test::UploadedFile.new(big.path, "text/plain")
      }
    end
    pe = PromptNavigator::PromptExecution.order(:id).last
    assert_equal "too big", pe.prompt
  ensure
    big&.close!
  end

  test "guess_document_mime falls back on extension when content_type is missing" do
    ctrl = ChatsController.new
    assert_equal "text/markdown", ctrl.send(:guess_document_mime, "readme.md")
    assert_equal "text/csv",      ctrl.send(:guess_document_mime, "data.csv")
    assert_equal "text/plain",    ctrl.send(:guess_document_mime, "unknown.xyz")
    assert_equal "application/json", ctrl.send(:guess_document_mime, "conf.json")
    assert_equal "application/pdf", ctrl.send(:guess_document_mime, "paper.pdf")
  end

  test "POST /chats with a PDF document stores it as a data-URI link with application/pdf mime" do
    assert_difference -> { PromptNavigator::PromptExecution.count }, 1 do
      post chats_path, params: {
        message: "read this",
        document: fixture_file_upload("tiny.pdf", "application/pdf")
      }
    end
    pe = PromptNavigator::PromptExecution.order(:id).last
    assert_match(/\A\[tiny\.pdf\]\(data:application\/pdf;base64,[^\)]+\)\s+read this/, pe.prompt)
  end

  test "PDF over 10 MB is rejected while a PDF between 1-10 MB is accepted (the text-doc 1 MB cap doesn't apply to PDFs)" do
    # A 2 MB PDF should be accepted (over the text cap, under the PDF cap).
    accepted_pdf = Tempfile.new([ "med", ".pdf" ], binmode: true)
    accepted_pdf.write("%PDF-1.4\n" + ("x" * (2 * 1024 * 1024)))
    accepted_pdf.rewind
    post chats_path, params: {
      message: "accept me",
      document: Rack::Test::UploadedFile.new(accepted_pdf.path, "application/pdf")
    }
    pe = PromptNavigator::PromptExecution.order(:id).last
    assert_match(/\A\[.*\]\(data:application\/pdf/, pe.prompt, "2 MB PDF should be accepted")

    # An 11 MB PDF should be rejected.
    big_pdf = Tempfile.new([ "big", ".pdf" ], binmode: true)
    big_pdf.write("%PDF-1.4\n" + ("x" * (11 * 1024 * 1024)))
    big_pdf.rewind
    post chats_path, params: {
      message: "too big",
      document: Rack::Test::UploadedFile.new(big_pdf.path, "application/pdf")
    }
    pe = PromptNavigator::PromptExecution.order(:id).last
    assert_equal("too big", pe.prompt, "11 MB PDF should be rejected")
  ensure
    accepted_pdf&.close!
    big_pdf&.close!
  end
end
