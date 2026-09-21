defmodule JidoSwarmWeb.Router do
  use JidoSwarmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JidoSwarmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", JidoSwarmWeb do
    pipe_through :browser

    live "/", ChatLive, :index
  end

  # Probes, on the api pipeline so they neither fetch a session nor render a
  # layout, and excluded from force_ssl in config/prod.exs.
  scope "/health", JidoSwarmWeb do
    pipe_through :api

    get "/", HealthController, :show
    get "/ready", HealthController, :ready
  end

  # Other scopes may use custom stacks.
  # scope "/api", JidoSwarmWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:jido_swarm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: JidoSwarmWeb.Telemetry
    end
  end
end
