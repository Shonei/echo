defmodule TestCors do
  import Plug.Conn
  def run do
    options = [
      origin: [~r/^https?:\/\/(.*\.shonei\.me|shonei\.dev|apps\.shonei\.dev)$/],
      methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS", "PUT"],
      max_age: 86400
    ]
    plug_opts = CORSPlug.init(options)
    
    conn = %Plug.Conn{}
      |> put_req_header("origin", "https://app.shonei.me")
      |> CORSPlug.call(plug_opts)
      
    IO.inspect(get_resp_header(conn, "access-control-allow-origin"))
  end
end
TestCors.run()
