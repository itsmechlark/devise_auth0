# frozen_string_literal: true

class PingController < ApplicationController
  skip_before_action :authenticate_auth0!, only: :show

  def index
    render(json: { message: "pong", auth0_id: current_auth0.auth0_id })
  end

  def login
  end
end
