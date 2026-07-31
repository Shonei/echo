defmodule EchoWeb.BlogController do
  use EchoWeb, :controller

  alias Echo.Content
  alias Echo.Content.Blog

  action_fallback EchoWeb.FallbackController

  def index(conn, params) do
    blogs = Content.list_blogs(build_blog_list_filters(conn, params))
    render(conn, :index, blogs: blogs)
  end

  def create(conn, params) do
    blog_params = params["blog"] || %{}

    with {:ok, validated_params} <- validate_and_convert_tags(blog_params),
         {:ok, %Blog{} = blog} <- Content.create_blog(validated_params) do
      conn
      |> put_status(:created)
      |> render(:show, blog: blog)
    end
  end

  def show(conn, %{"id" => id}) do
    blog = Content.get_blog_by_id_or_slug!(id)

    if visible?(conn, blog) do
      render(conn, :show, blog: blog)
    else
      # 404 rather than 403 so an unpublished blog's existence stays private
      {:error, :not_found}
    end
  end

  def update(conn, %{"id" => id, "blog" => blog_params}) do
    blog = Content.get_blog!(id)

    with {:ok, validated_params} <- validate_and_convert_tags(blog_params),
         {:ok, %Blog{} = blog} <- Content.update_blog_metadata(blog, validated_params) do
      render(conn, :show, blog: blog)
    end
  end

  def update(_conn, %{"id" => _id}), do: {:error, :missing_param, "blog"}

  # Only an authenticated editor may see anything other than public blogs. The
  # status param is ignored for anonymous callers rather than honoured, so
  # ?status=draft returns nothing instead of leaking.
  defp build_blog_list_filters(conn, params) do
    if authenticated?(conn) do
      case Map.get(params, "status") do
        status when is_binary(status) and status != "" -> %{status: status}
        _ -> %{}
      end
    else
      %{status: "public"}
    end
  end

  defp visible?(conn, %Blog{status: status}), do: authenticated?(conn) or status == "public"

  defp authenticated?(conn), do: conn.assigns[:authenticated?] == true

  # Validates that tags are either an empty map or a map of string/string pairs,
  # then converts to a byte array (JSON encoded binary) for storage
  defp validate_and_convert_tags(blog_params) do
    case Map.get(blog_params, "tags") do
      nil ->
        {:ok, blog_params}

      tags when is_map(tags) ->
        if valid_tags_map?(tags) do
          {:ok, Map.put(blog_params, "tags", Jason.encode!(tags))}
        else
          {:error, :invalid_tags}
        end

      _invalid ->
        {:error, :invalid_tags}
    end
  end

  # Tags must be a map where all keys and values are strings (an empty map
  # trivially satisfies this)
  defp valid_tags_map?(tags) when is_map(tags) do
    Enum.all?(tags, fn {key, value} ->
      is_binary(key) and is_binary(value)
    end)
  end

  def update_content(conn, %{"blog_id" => blog_id, "content" => content}) do
    blog = Content.get_blog!(blog_id)

    with {:ok, %Blog{} = blog} <- Content.update_blog_content(blog, content) do
      render(conn, :show, blog: blog)
    end
  end

  def update_content(_conn, %{"blog_id" => _blog_id}), do: {:error, :missing_param, "content"}

  def delete(conn, %{"id" => id}) do
    blog = Content.get_blog!(id)

    with {:ok, %Blog{}} <- Content.delete_blog(blog) do
      send_resp(conn, :no_content, "")
    end
  end
end
