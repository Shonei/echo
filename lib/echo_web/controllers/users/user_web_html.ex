defmodule EchoWeb.UserWebHTML do
  @moduledoc """
  This module contains pages rendered by UserWebController.

  See the `user_web_html` directory for all templates.
  """
  use EchoWeb, :html

  embed_templates "user_web_html/*"
end
