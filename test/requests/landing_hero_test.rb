require "test_helper"

# The landing pitch shown to a visitor with no messages yet (chats#new).
#
# It had no tests at all. The widget — the assistant embedded in another
# site's page — is one of the project's distinctive pieces and was absent
# from the pitch entirely, so these pin that it is there, alongside the
# three features that were.
class LandingHeroTest < ActionDispatch::IntegrationTest
  setup do
    stub_request(:get, "#{Rails.configuration.llm_service_base_url}/api/llms")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { llms: [] }.to_json)
  end

  test "an anonymous visitor sees the pitch" do
    get root_path

    assert_response :success
    assert_select "#landing-hero h1"
  end

  test "it pitches all four capabilities, one card each" do
    get root_path

    headings = css_select("#landing-hero .lh-caption strong").map(&:text)
    assert_equal 4, headings.length, "expected four pitch cards, got: #{headings.inspect}"
    assert(headings.any? { |h| h.match?(/branch/i) },  "no branching card: #{headings.inspect}")
    assert(headings.any? { |h| h.match?(/model/i) },   "no model-switching card: #{headings.inspect}")
    assert(headings.any? { |h| h.match?(/MCP/i) },     "no MCP card: #{headings.inspect}")
    assert(headings.any? { |h| h.match?(/own site/i) }, "no widget card: #{headings.inspect}")
  end

  test "the widget card links to a live example on a real host site" do
    get root_path

    link = css_select("#landing-hero a[href*='pubdictionaries']").first
    assert link, "the widget card should point at a working embed"
    assert_equal "_blank", link["target"], "a link off this site should open in a new tab"
    assert_includes link["rel"].to_s, "noopener"
  end

  test "the widget mock reads as a different site, not this one" do
    get root_path

    viz = css_select("#landing-hero .lh-viz-embed").first
    assert viz, "no widget mock rendered"
    # The host bar naming another site is what makes the card legible; without
    # it the mock is just another chat panel.
    assert_match(/pubdictionaries\.org/, css_select("#landing-hero .lh-host-bar").first.text)
  end

  test "the tagline mentions it too, so the cards and the tagline agree" do
    get root_path

    tagline = css_select("#landing-hero .landing-hero-tagline").first.text
    assert_match(/your own web tool/i, tagline)
  end

  # Dashed strokes are reserved: prompt_navigator draws supplement ("cited as
  # reference") edges dashed, and chats.css gives the cited card a dashed
  # border to match. The branch arc is a parent->child edge, so dashing it
  # would claim the wrong relationship.
  test "the branch arc is solid, because dashed means reference" do
    get root_path

    hero = css_select("#landing-hero").first.to_html
    assert_includes hero, "lh-branch-arc", "no branch arc rendered"
    refute_match(/stroke-dasharray/, hero,
                 "a dashed edge in the pitch reads as a reference, not a branch")
  end

  # Both marks are the same parent->child edge. The straight one used to be a
  # "↓" character, whose weight cannot be set — font-weight does nothing to a
  # glyph that comes from a single-weight fallback font — so it could never be
  # matched to the curve. Drawn, they are the same line by construction.
  test "both lineage marks are drawn with the same stroke" do
    get root_path

    strokes = css_select("#landing-hero .lh-viz-branch path").map { |p| p["stroke"] }.compact
    assert_operator strokes.length, :>=, 2, "expected a curved and a straight lineage mark"
    assert_equal 1, strokes.uniq.length, "lineage marks disagree on colour: #{strokes.inspect}"

    widths = css_select("#landing-hero .lh-viz-branch path").map { |p| p["stroke-width"] }.compact
    assert_equal 1, widths.uniq.length, "lineage marks disagree on width: #{widths.inspect}"
  end

  test "the pitch disappears once the conversation starts" do
    # chats/create.turbo_stream.erb removes it; the partial is only rendered
    # on the empty-state page.
    get root_path
    assert_select "#landing-hero", 1
  end
end
