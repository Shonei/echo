defmodule EchoWeb.RevisionController do
  use EchoWeb, :controller

  alias Echo.Content
  alias Echo.Content.Revision

  action_fallback EchoWeb.FallbackController

  def index(conn, %{"blog_id" => blog_id}) do
    revisions = Content.list_blog_revisions(blog_id)
    render(conn, :index, revisions: revisions)
  end

  def create(conn, %{"blog_id" => blog_id, "revision" => revision_params}) do
    with {:ok, %Revision{} = revision} <- Content.create_revision(blog_id, revision_params) do
      conn
      |> put_status(:created)
      |> render(:show, revision: revision)
    end
  end
end
