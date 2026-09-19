defmodule JidoSwarmWeb.PageController do
  use JidoSwarmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
