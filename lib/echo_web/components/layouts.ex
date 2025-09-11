defmodule EchoWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use EchoWeb, :controller` and
  `use EchoWeb, :live_view`.
  """
  use EchoWeb, :html

  embed_templates "layouts/*"
end
