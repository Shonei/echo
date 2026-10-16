defmodule EchoWeb.UnoChessControllerTest do
  use EchoWeb.ConnCase, async: true

  alias Echo.UnoChess.Games

  @capture """
  8 . . . . k . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . . p . . . .
  4 . . . . P . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . K . . .
  """

  test "POST /api/v1/uno-chess/games creates a deal and returns white's token", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/uno-chess/games")
    assert %{"data" => data} = json_response(conn, 201)

    assert data["seat"] == "white"
    assert is_binary(data["token"])

    game = data["game"]
    assert is_binary(game["room_code"])
    assert game["status"] == "active"
    assert game["winner"] == nil
    assert game["turn"] == "white"
    assert game["you"] == "white"
    assert game["seats"] == %{"white" => true, "black" => false}
    assert game["deck_count"] == 64
    assert game["discard_count"] == 0
    assert map_size(game["board"]) == 32
    assert game["board"]["e2"] == %{"color" => "white", "kind" => "pawn"}
    assert game["board"]["e8"] == %{"color" => "black", "kind" => "king"}
    refute Map.has_key?(game, "white_token")
    refute Map.has_key?(game, "black_token")
  end

  test "GET /api/v1/uno-chess/games/:room_code identifies the caller's seat or spectator", %{
    conn: conn
  } do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1"])
    {:ok, black_token} = Games.claim_black(game)

    spectator = get(conn, ~p"/api/v1/uno-chess/games/#{game.room_code}")
    assert %{"data" => spec_data} = json_response(spectator, 200)
    assert spec_data["you"] == nil
    assert spec_data["seats"] == %{"white" => true, "black" => true}

    white =
      conn
      |> put_req_header("authorization", "Bearer " <> game.white_token)
      |> get(~p"/api/v1/uno-chess/games/#{game.room_code}")

    assert %{"data" => %{"you" => "white"}} = json_response(white, 200)

    black =
      conn
      |> put_req_header("x-player-token", black_token)
      |> get(~p"/api/v1/uno-chess/games/#{game.room_code}")

    assert %{"data" => %{"you" => "black"}} = json_response(black, 200)
  end

  test "GET /api/v1/uno-chess/games/:room_code returns 404 for unknown rooms", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/uno-chess/games/missing-room")
    assert json_response(conn, 404)
  end

  test "POST /api/v1/uno-chess/games/:room_code/join claims black once", %{conn: conn} do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1"])

    first = post(conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/join")
    assert %{"data" => data} = json_response(first, 200)
    assert data["seat"] == "black"
    assert is_binary(data["token"])
    assert data["game"]["you"] == "black"
    assert data["game"]["seats"] == %{"white" => true, "black" => true}

    second = post(conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/join")
    assert %{"errors" => %{"detail" => "seat_taken"}} = json_response(second, 409)
  end

  test "POST /api/v1/uno-chess/games/:room_code/play plays a full turn and enforces seats", %{
    conn: conn
  } do
    {:ok, game} =
      Games.create_game(
        room_code: unique("room"),
        board: @capture,
        deck: ["R", "1", "T"]
      )

    {:ok, black_token} = Games.claim_black(game)
    white_conn = put_req_header(conn, "authorization", "Bearer " <> game.white_token)
    black_conn = put_req_header(conn, "authorization", "Bearer " <> black_token)

    anon = post(conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "draw"})
    assert %{"errors" => %{"detail" => "invalid_token"}} = json_response(anon, 401)

    wrong_turn =
      post(black_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "draw"})

    assert %{"errors" => %{"detail" => "not_your_turn"}} = json_response(wrong_turn, 422)

    # White draws Reverse ("R") -> card stays nil, must draw again
    draw_reverse =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "draw"})

    assert %{
             "data" => %{
               "game" => %{"card" => nil, "discard_count" => 1},
               "events" => [
                 %{"type" => "card_drawn", "color" => "white", "card" => %{"type" => "reverse"}}
               ]
             }
           } = json_response(draw_reverse, 200)

    # White draws Move 1 ("1") -> legal_moves populated
    draw_one =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "draw"})

    assert %{
             "data" => %{
               "game" => %{
                 "card" => %{"type" => "move", "count" => 1, "code" => "1"},
                 "remaining" => 1,
                 "legal_moves" => legal_moves
               }
             }
           } = json_response(draw_one, 200)

    assert "e4-d5" in legal_moves

    # White captures d5 using from/to params
    move_res =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "move",
        "from" => "e4",
        "to" => "d5"
      })

    assert %{
             "data" => %{
               "game" => %{
                 "remaining" => 0,
                 "can_undo" => true,
                 "can_end_turn" => true,
                 "graveyard" => %{"black" => ["pawn"], "white" => []}
               },
               "events" => [
                 %{
                   "type" => "piece_moved",
                   "move" => "e4-d5",
                   "captured" => %{"color" => "black", "kind" => "pawn"},
                   "remaining" => 0
                 }
               ]
             }
           } = json_response(move_res, 200)

    # White undoes, then replays with "move" string, then ends turn
    undo_res =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "undo"})

    assert %{"data" => %{"game" => %{"remaining" => 1, "can_undo" => false}}} =
             json_response(undo_res, 200)

    _ =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "move",
        "move" => "e4-d5"
      })

    end_white =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "end_turn"
      })

    assert %{"data" => %{"game" => %{"turn" => "black", "card" => nil}}} =
             json_response(end_white, 200)

    # Black draws Restore 2 ("T"), sees legal_drops for pawn, drops on d6, and ends turn
    draw_restore =
      post(black_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{"action" => "draw"})

    assert %{
             "data" => %{
               "game" => %{
                 "card" => %{"type" => "restore", "count" => 2, "code" => "T"},
                 "legal_drops" => %{"pawn" => pawn_drops}
               }
             }
           } = json_response(draw_restore, 200)

    assert "d6" in pawn_drops

    drop_res =
      post(black_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "drop",
        "kind" => "pawn",
        "square" => "d6"
      })

    assert %{
             "data" => %{
               "game" => %{
                 "remaining" => 1,
                 "can_end_turn" => true,
                 "graveyard" => %{"black" => [], "white" => []}
               }
             }
           } = json_response(drop_res, 200)

    end_black =
      post(black_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "end_turn"
      })

    assert %{
             "data" => %{
               "game" => %{
                 "turn" => "white",
                 "board" => %{
                   "d5" => %{"color" => "white", "kind" => "pawn"},
                   "d6" => %{"color" => "black", "kind" => "pawn"}
                 }
               }
             }
           } = json_response(end_black, 200)
  end

  test "POST /api/v1/uno-chess/games/:room_code/play with forfeit ends the game and awards victory to opponent",
       %{conn: conn} do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1"])
    {:ok, black_token} = Games.claim_black(game)
    white_conn = put_req_header(conn, "authorization", "Bearer " <> game.white_token)
    black_conn = put_req_header(conn, "authorization", "Bearer " <> black_token)

    res =
      post(black_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "forfeit"
      })

    assert %{
             "data" => %{
               "game" => %{
                 "status" => "forfeit",
                 "winner" => "white",
                 "turn" => nil
               },
               "events" => [
                 %{"type" => "forfeited", "color" => "black", "winner" => "white"}
               ]
             }
           } = json_response(res, 200)

    after_over =
      post(white_conn, ~p"/api/v1/uno-chess/games/#{game.room_code}/play", %{
        "action" => "draw"
      })

    assert %{"errors" => %{"detail" => "game_over"}} = json_response(after_over, 422)
  end
end
