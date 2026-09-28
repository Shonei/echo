defmodule Echo.UnoChess.RulesTest do
  use ExUnit.Case, async: true

  import Echo.UnoChess.Scenario

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Move
  alias Echo.UnoChess.Rules

  # Copy one of these tests to add a scenario. Rank 8 is the first line.
  # White is uppercase, Black is lowercase, `.` is empty.
  # Moves are "e2-e4" or "e7-e8q". Pass :captured, :piece_at, and :empty
  # to assert_legal/4 when the landing square matters.

  @pawn_on_e4 """
  8 . . . . k . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . . p . . . .
  4 . . . . P . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . K . . .
  """

  describe "pawns" do
    test "push one square, capture diagonally, and refuse the other steps" do
      assert_legal(@pawn_on_e4, :white, "e4-e5",
        captured: nil,
        empty: "e4",
        piece_at: {"e5", {:white, :pawn}}
      )

      assert_legal(@pawn_on_e4, :white, "e4-d5",
        captured: {:black, :pawn},
        piece_at: {"d5", {:white, :pawn}}
      )

      assert_illegal(@pawn_on_e4, :white, "e4-e6", :illegal_geometry)
      assert_illegal(@pawn_on_e4, :white, "e4-e3", :illegal_geometry)
      assert_illegal(@pawn_on_e4, :white, "e4-d4", :illegal_geometry)
      assert_illegal(@pawn_on_e4, :white, "e4-f5", :illegal_geometry)
      assert_illegal(@pawn_on_e4, :white, "e4-e5q", :promotion_illegal)
    end

    test "the same pawn can move again from the square it just reached" do
      board = assert_legal(@pawn_on_e4, :white, "e4-e5")

      assert {:ok, _next, nil} = Rules.apply_move(board, :white, "e5-e6")
    end

    test "a pawn on its start rank may step one or two squares" do
      board = Board.initial()

      assert {:ok, _, nil} = Rules.apply_move(board, :white, "e2-e3")
      assert {:ok, next, nil} = Rules.apply_move(board, :white, "e2-e4")
      assert Board.get(next, "e4") == {:white, :pawn}
      assert {:ok, _, nil} = Rules.apply_move(board, :black, "e7-e5")
      assert_illegal(Board.to_diagram(board), :white, "e2-e5", :illegal_geometry)
    end

    test "a double step stops when either square in front is occupied" do
      blocked_mid = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . p . . .
      2 . . . . P . . .
      1 . . . . K . . .
      """

      blocked_dest = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . p . . .
      3 . . . . . . . .
      2 . . . . P . . .
      1 . . . . K . . .
      """

      assert_illegal(blocked_mid, :white, "e2-e4", :path_blocked)
      assert_illegal(blocked_dest, :white, "e2-e4", :illegal_geometry)
    end

    test "black pawns move down the board and capture that way" do
      diagram = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . p . . .
      4 . . . P . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_legal(diagram, :black, "e5-e4", piece_at: {"e4", {:black, :pawn}})
      assert_legal(diagram, :black, "e5-d4", captured: {:white, :pawn})
      assert_illegal(diagram, :black, "e5-e6", :illegal_geometry)
      assert_illegal(diagram, :black, "e5-e3", :illegal_geometry)
    end

    test "a pawn promotes when it reaches the last rank" do
      white = """
      8 . . . . . . . k
      7 . . . . P . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      black = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . p . . .
      1 . . . K . . . .
      """

      assert_illegal(white, :white, "e7-e8", :promotion_required)

      assert_legal(white, :white, "e7-e8q",
        captured: nil,
        empty: "e7",
        piece_at: {"e8", {:white, :queen}}
      )

      assert_legal(white, :white, "E7-E8R", piece_at: {"e8", {:white, :rook}})
      assert_legal(black, :black, "e2-e1n", piece_at: {"e1", {:black, :knight}})
    end

    test "an empty diagonal is not a capture, including the en passant square" do
      diagram = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . p P . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_illegal(diagram, :white, "e5-d6", :illegal_geometry)
    end
  end

  describe "knights, bishops, rooks, queens, and kings" do
    test "a knight jumps and only in an L" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . p p p . . . .
      2 . p N p . . . .
      1 . p p p K . . .
      """

      assert_legal(diagram, :white, "c2-b4", empty: "c2", piece_at: {"b4", {:white, :knight}})
      assert_legal(diagram, :white, "c2-a3")
      assert_legal(diagram, :white, "c2-d4")
      assert_illegal(diagram, :white, "c2-c3", :illegal_geometry)
      assert_illegal(diagram, :white, "c2-e1", :friendly_fire)
    end

    test "the opening knight move is legal from the home square" do
      assert {:ok, _, nil} = Rules.apply_move(Board.initial(), :white, "b1-c3")
      assert {:ok, _, nil} = Rules.apply_move(Board.initial(), :white, "g1-f3")
    end

    test "a bishop travels a clear diagonal and stops at the first piece" do
      clear = """
      8 k . . . . . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 B . . . . . . K
      """

      blocked = """
      8 k . . . . . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . p . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 B . . . . . . K
      """

      assert_legal(clear, :white, "a1-h8", captured: nil, piece_at: {"h8", {:white, :bishop}})
      assert_legal(clear, :white, "a1-c3")
      assert_illegal(clear, :white, "a1-a3", :illegal_geometry)
      assert_illegal(blocked, :white, "a1-h8", :path_blocked)
      assert_legal(blocked, :white, "a1-d4", captured: {:black, :pawn})
    end

    test "a rook travels a clear rank or file" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 P . . . . . . .
      1 R . . . . . . K
      """

      assert_illegal(diagram, :white, "a1-a2", :friendly_fire)
      assert_illegal(diagram, :white, "a1-a4", :path_blocked)
      assert_illegal(diagram, :white, "a1-b2", :illegal_geometry)
      assert_legal(diagram, :white, "a1-b1")
    end

    test "a queen combines the rook and the bishop" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . q . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_legal(diagram, :black, "f6-f2")
      assert_legal(diagram, :black, "f6-a1")
      assert_illegal(diagram, :black, "f6-e4", :illegal_geometry)
    end

    test "a king moves one square and does not castle" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_legal(diagram, :white, "e1-e2", piece_at: {"e2", {:white, :king}})
      assert_legal(diagram, :white, "e1-d2")
      assert_illegal(diagram, :white, "e1-e3", :illegal_geometry)
      assert_illegal(diagram, :white, "e1-g1", :illegal_geometry)
    end
  end

  describe "ownership and captures" do
    test "the mover must be the piece's owner, and the king cannot be taken" do
      diagram = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . P . . .
      1 R . . . K . . .
      """

      assert_illegal(diagram, :white, "e7-e5", :no_piece)
      assert_illegal(diagram, :black, "e2-e4", :wrong_color)
      assert_illegal(diagram, :white, "a1-a1", :illegal_geometry)
      assert_illegal(diagram, :white, "e2-e9", :off_board)
      assert_illegal(diagram, :white, "e2e4", :invalid_move)

      corner = """
      8 . . . . . . k .
      7 . . . . . . . P
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_illegal(corner, :white, "h7-g8", :cannot_capture_king)
    end

    test "a rook takes the queen and reports the captured piece" do
      diagram = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . q . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . R . . . K
      """

      assert_legal(diagram, :white, "d1-d5",
        captured: {:black, :queen},
        empty: "d1",
        piece_at: {"d5", {:white, :rook}}
      )
    end

    test "coordinates off the board are rejected" do
      board = Board.initial()
      move = %Move{from: {4, 1}, to: {4, 8}}

      assert {:error, :off_board} = Rules.apply_move(board, :white, move)
    end
  end

  describe "check" do
    test "a queen checks along an open line and a blocker closes it" do
      open = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . Q . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      blocked = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . p . . .
      5 . . . . . . . .
      4 . . . . Q . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_check(open, :black)
      refute_check(open, :white)
      refute_check(blocked, :black)
    end

    test "knights and pawns attack their own shapes" do
      knight = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . . N .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      pawn_attacks = """
      8 . . . . . . . k
      7 . . . . . . P .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      pawn_pushes = """
      8 . . . . . . . k
      7 . . . . . . . P
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      assert_check(knight, :black)
      assert_check(pawn_attacks, :black)
      refute_check(pawn_pushes, :black)
    end

    test "a move that leaves the mover in check is still applied" do
      diagram = """
      8 k . . . . . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . P . . .
      1 r . . . K . . .
      """

      assert_check(diagram, :white)

      next = assert_legal(diagram, :white, "e2-e4", piece_at: {"e4", {:white, :pawn}})
      assert Rules.in_check?(next, :white)
    end
  end

  describe "mate, stalemate, and pins" do
    test "a protected queen on g7 mates the king in the corner" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . Q .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . . . R K
      """

      assert_mate(diagram, :black)
    end

    test "an unprotected checking rook is not mate" do
      diagram = """
      8 . . . . . . R k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . . . . K
      """

      assert_check(diagram, :black)
      refute_mate(diagram, :black)
      assert "h8-g8" in encoded_moves(diagram, :black)
    end

    test "a king with no legal move and no check is stalemated" do
      diagram = """
      8 k . . . . . . .
      7 . . . . . . . .
      6 . Q . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . . . . K
      """

      assert_stalemate(diagram, :black)
    end

    test "a pinned rook may slide along the pin and may not step off it" do
      diagram = """
      8 . . . . r . . k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . R . . .
      1 . . . . K . . .
      """

      assert "e2-d2" in encoded_moves(diagram, :white, :pseudo)
      refute "e2-d2" in encoded_moves(diagram, :white, :legal)
      assert "e2-e4" in encoded_moves(diagram, :white, :legal)
      assert "e1-d1" in encoded_moves(diagram, :white, :legal)
    end
  end

  describe "drops" do
    @empty """
    ........
    ........
    ........
    ........
    ........
    ........
    ........
    ........
    """

    test "pieces land on the owner's home half, and pawns avoid the end ranks" do
      assert_drop(@empty, :white, :queen, "d1")
      assert_drop(@empty, :white, :bishop, "c1")
      assert_drop(@empty, :white, :pawn, "e2")
      assert_drop(@empty, :white, :pawn, "e4")
      assert_drop(@empty, :black, :queen, "a5")
      assert_drop(@empty, :black, :pawn, "e7")

      assert_drop_illegal(@empty, :white, :pawn, "e1", :illegal_pawn_drop)
      assert_drop_illegal(@empty, :white, :pawn, "e5", :off_home_half)
      assert_drop_illegal(@empty, :white, :queen, "e8", :off_home_half)
      assert_drop_illegal(@empty, :black, :pawn, "a8", :illegal_pawn_drop)
      assert_drop_illegal(@empty, :black, :queen, "a4", :off_home_half)
      assert_drop_illegal(@empty, :white, :king, "e2", :invalid_piece)
      assert_drop_illegal(@empty, :white, :pawn, "e9", :off_board)
    end

    test "a drop cannot land on an occupied square" do
      diagram = """
      8 . . . . . . . k
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . P . . .
      1 . . . . K . . .
      """

      assert_drop_illegal(diagram, :white, :queen, "e2", :occupied)
    end
  end
end
