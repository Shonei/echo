defmodule EchoWeb.RevisionController do
  use EchoWeb, :controller

  alias Echo.Content

  action_fallback EchoWeb.FallbackController

  def index(conn, %{"blog_id" => blog_id}) do
    revisions = Content.list_blog_revisions(blog_id)
    render(conn, :index, revisions: revisions)
  end
end
