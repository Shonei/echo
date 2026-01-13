defmodule EchoWeb.RevisionController do
  use EchoWeb, :controller

  alias Echo.Content

  action_fallback EchoWeb.FallbackController

  def index(conn, %{"blog_id" => blog_id}) do
    blog = Content.get_blog!(blog_id)
    revisions = blog.revisions |> Enum.sort_by(& &1.version, :desc)
    render(conn, :index, revisions: revisions)
  end

  def show(conn, %{"id" => id}) do
    revision = Content.get_revision!(id)
    render(conn, :show, revision: revision)
  end
end
