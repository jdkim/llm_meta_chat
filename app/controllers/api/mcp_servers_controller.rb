# frozen_string_literal: true

class Api::McpServersController < ApplicationController
  # Anon visitors are allowed — they see only `public_to_anonymous` MCP
  # servers, per the hub's visibility rules. Signed-in users additionally
  # see their own + all `public` servers.
  skip_before_action :authenticate_user!, raise: false

  def index
    render json: { mcp_servers: fetch_servers }
  end

  def tools
    render json: { tools: fetch_tools(params[:uuid]) }
  end

  private

  def fetch_servers
    if user_signed_in?
      LlmMetaClient::ServerResource.fetch_mcp_servers(current_user.jwt_token)
    else
      # Bypass the gem — v1.8.0's fetch_mcp_servers early-returns [] on a
      # blank JWT, so we hit the hub directly for the anon path. The hub's
      # /api/mcp_servers accepts unauthed requests and returns only
      # `public_to_anonymous` servers (with `shared_by` stripped for privacy).
      unauthed_hub_get("api/mcp_servers")["mcp_servers"] || []
    end
  end

  def fetch_tools(mcp_server_uuid)
    return [] if mcp_server_uuid.blank?
    if user_signed_in?
      LlmMetaClient::ServerResource.fetch_mcp_tools(current_user.jwt_token, mcp_server_uuid)
    else
      unauthed_hub_get("api/mcp_servers/#{mcp_server_uuid}/tools")["tools"] || []
    end
  end

  def unauthed_hub_get(path)
    base_url = Rails.configuration.llm_service_base_url
    response = HTTParty.get("#{base_url}/#{path}", timeout: 5)
    response.success? ? (response.parsed_response || {}) : {}
  rescue StandardError => e
    Rails.logger.error "Error fetching #{path} unauthed: #{e.class} - #{e.message}"
    {}
  end
end
