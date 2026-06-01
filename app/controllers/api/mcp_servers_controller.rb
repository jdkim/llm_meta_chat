# frozen_string_literal: true

class Api::McpServersController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  before_action :authenticate_user!

  def index
    jwt_token = current_user.jwt_token
    mcp_servers = LlmMetaClient::ServerResource.fetch_mcp_servers(jwt_token)
    render json: { mcp_servers: mcp_servers }
  end

  def tools
    jwt_token = current_user.jwt_token
    tools = LlmMetaClient::ServerResource.fetch_mcp_tools(jwt_token, params[:uuid])
    render json: { tools: tools }
  end
end
