defmodule EchoWeb.HomeLinksTest do
  @moduledoc """
  The home page is the index of the mini-apps, so every one of them has to be
  reachable from it and get you back to it. Both directions drifted once --
  skills shipped without either -- so they are checked rather than remembered.
  """
  use EchoWeb.ConnCase, async: true

  @templates Path.wildcard("lib/echo_web/controllers/**/*.html.heex")
  @home "lib/echo_web/controllers/page_html/home.html.heex"

  test "every page links back to the home page" do
    for template <- @templates -- [@home] do
      assert File.read!(template) =~ ~s(href="/"),
             "#{template} has no link to the home page"
    end
  end

  test "the home page links to every mini-app" do
    home = File.read!(@home)

    for path <- ~w(/echo/request /chat /assets /ai-messages /agent-chat/new /skills) do
      assert home =~ ~s(href="#{path}"), "the home page does not link to #{path}"
    end
  end
end
