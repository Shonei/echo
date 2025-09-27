defmodule EchoWeb.ChatWebHTML do
  @moduledoc """
  This module contains pages rendered by ChatWebController.

  See the `chat_web_html` directory for all templates.
  """
  use EchoWeb, :html

  embed_templates "chat_web_html/*"
end
