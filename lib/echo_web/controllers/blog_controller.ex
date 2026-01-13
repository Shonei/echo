defmodule EchoWeb.BlogController do
  use EchoWeb, :controller

  alias Echo.Content
  alias Echo.Content.Blog

  action_fallback EchoWeb.FallbackController

  def index(conn, _params) do
    blogs = Content.list_blogs()
    render(conn, :index, blogs: blogs)
  end

  def create(conn, %{"blog" => blog_params}) do
    with {:ok, %Blog{} = blog} <- Content.create_blog(blog_params) do
      blog = Content.get_blog!(blog.id)
      conn
      |> put_status(:created)
      |> render(:show, blog: blog)
    end
  end

  def show(conn, %{"id" => id}) do
    blog = Content.get_blog!(id)
    render(conn, :show, blog: blog)
  end

  def update(conn, %{"id" => id, "blog" => blog_params}) do
    blog = Content.get_blog!(id)

    with {:ok, %Blog{} = blog} <- Content.update_blog(blog, blog_params) do
      # Reload to ensure we have revisions preloaded and latest data
      blog = Content.get_blog!(blog.id)
      render(conn, :show, blog: blog)
    end
  end

  def delete(conn, %{"id" => id}) do
    blog = Content.get_blog!(id)

    with {:ok, %Blog{}} <- Content.delete_blog(blog) do
      send_resp(conn, :no_content, "")
    end
  end
end
