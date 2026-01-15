defmodule EchoWeb.RevisionJSON do
  alias Echo.Content.Revision

  def index(%{revisions: revisions}) do
    %{data: for(revision <- revisions, do: data(revision))}
  end

  def show(%{revision: revision}) do
    %{data: data(revision)}
  end

  defp data(%Revision{} = revision) do
    %{
      id: revision.id,
      version: revision.version,
      content: revision.content,
      note: revision.note,
      created_at: revision.inserted_at,
      blog_id: revision.blog_id
    }
  end
end
