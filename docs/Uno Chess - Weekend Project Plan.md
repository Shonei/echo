# **Uno Chess — Technical Specification & Weekend Plan**

# **1\. Executive Summary & Overview**

**Uno Chess** is a high-velocity, turn-based multiplayer web application combining standard chess tactics with dynamic Uno card mechanics. Players begin each turn by drawing an Uno card from a server-managed deck. The drawn card dictates allowed turn actions, including multi-move allocations, graveyard piece restorations, or instant turn rerolls.

The core objective of this project is to build a robust, low-latency multiplayer game within a two-day weekend scope using Elixir/Phoenix for authoritative game orchestration and React/Konva.js for performant canvas rendering.

---

# **2\. Core Mechanics & Game Rules**

## **Deck Composition & Probabilities**

The deck operates on weighted probability distribution to balance tempo acceleration and chaos:

* **Movement Cards (1, 2, 3):** Dictate the exact number of sub-moves a player must execute in sequence.  
  * **Card 2 (High Frequency):** Primary movement driver (\~50% deck concentration).  
  * **Card 1 (Medium Frequency):** Standard chess tempo (\~30% deck concentration).  
  * **Card 3 (Low Frequency):** High-impact multi-move bursts (\~10% deck concentration).  
  * **Card 0:** Omitted entirely to prevent stagnant turns.  
* **Special Action Cards:**  
  * **Piece Restoration (+N):** Restores up to \$N\$ captured pieces from the player's graveyard.  
  * **Reverse (Reroll / Mulligan):** Instantly discarded on draw; player immediately draws a replacement card with no turn cost.

## **Mechanics & Constraints Specification**

| Mechanic | Behavioral Rule & Validation Rules |
| :---- | :---- |
| **Multi-Move Sub-Turns** | Card value \$N \\in {1, 2, 3}\$ mandates *exactly* \$N\$ valid piece moves before turn finalization. |
| **Graveyard Restoration (+N)** | Target location must be an empty square on the player's home half (Ranks 1–4 for White, 5–8 for Black). Pawns **cannot** be placed on Rank 1 or Rank 8\. |
| **Partial Restoration** | If graveyard contains \$\< N\$ pieces, restore maximum available pieces; unused restoration charges are forfeited. |
| **Check Blocking** | Restored pieces may be dropped onto squares to actively interrupt/block existing lines of check. |
| **Reverse Mechanics** | Triggers an immediate server-side redraw broadcast. Does not increment move count or penalize player. |
| **End-of-Turn Check Resolution** | Intermediate sub-moves may leave the King exposed to attack, provided the King is strictly safe when `end_turn` is invoked. |
| **Win Condition** | First player to deliver a fully legal Checkmate at the conclusion of their staged turn wins immediately. |

---

# **3\. Technology Stack & System Architecture**

## **Architectural Overview**

                      \+---------------------------------------+

                      |            Client (Browser)           |

                      |   React \+ Konva.js Canvas Board       |

                      \+-------------------+-------------------+

                                          |

                               WebSocket (Phoenix Channels)

                                          |

                      \+-------------------v-------------------+

                      |       Phoenix Application Server      |

                      |  \- Web Layer & Endpoint Handler       |

                      |  \- DynamicSupervisor & Registry       |

                      \+-------------------+-------------------+

                                          |

                                     Spawns/Routes

                                          |

                      \+-------------------v-------------------+

                      |      Authoritative Game Server        |

                      |     (Elixir GenServer Instance)       |

                      |  \- Staged vs Committed Turn State     |

                      |  \- Deck Management & Shuffling        |

                      \+-------------------+-------------------+

                                          |

                                    Appends Events

                                          |

                      \+-------------------v-------------------+

                      |         PostgreSQL Database           |

                      |  \- \`games\` (Metadata)                 |

                      |  \- \`game\_events\` (Append-Only)        |

                      \+---------------------------------------+

## **Component Stack**

* **Backend Framework:** Elixir `~> 1.15` & Phoenix `~> 1.7` (Utilizing WebSockets via Phoenix Channels for low-latency state synchronization).  
* **State Management:** GenServer per active game room, managed dynamically via `DynamicSupervisor` and tracked via Elixir `Registry`.  
* **Persistence & Event Sourcing:** PostgreSQL with an append-only event log (`game_events`) to allow full state reconstruction and complete auditability.  
* **Frontend Rendering Engine:** React 18 with `react-konva` for high-performance 2D canvas rendering of the board, drag-and-drop piece snapping, and movement pathing.  
* **Infrastructure & Hosting:** Railway (Single-replica deployment model maintaining in-memory GenServer registry).

## **Database Schema Design**

### **`games` Table**

l  
CREATE TABLE games (  
id UUID PRIMARY KEY DEFAULT gen\_random\_uuid(),  
room\_code VARCHAR(10) UNIQUE NOT NULL,  
white\_player\_id VARCHAR(64),  
black\_player\_id VARCHAR(64),  
status VARCHAR(20) NOT NULL DEFAULT 'pending', \-- pending, active, completed  
winner\_id VARCHAR(64),  
inserted\_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),  
updated\_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()  
);

\#\#\#\# \`game\_events\` Table (Event Store)

\`\`\`sql

CREATE TABLE game\_events (

    id BIGSERIAL PRIMARY KEY,

    game\_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,

    sequence\_number INT NOT NULL,

    event\_type VARCHAR(50) NOT NULL, \-- card\_drawn, submove\_staged, turn\_committed, turn\_rolled\_back

    payload JSONB NOT NULL,

    inserted\_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    UNIQUE(game\_id, sequence\_number)

);

---

# **4\. Turn Lifecycle & Message Sequence**

Client (Player)              GenServer (Game Engine)               Database (PostgreSQL)

       |                                |                                   |

       | \------ 1\. draw\_card \---------\> |                                   |

       |                                | \-- (Pulls card from deck state)   |

       | \<----- 2\. card\_drawn \--------- |                                   |

       |        (payload: card, N)      |                                   |

       |                                |                                   |

       | \--- 3\. stage\_submove(s) \----\> |                                   |

       |      (move\_piece / restore)    | \-- (Validates intermediate rules) |

       | \<--- 4\. submove\_staged \-------- | \-- (Updates \`staged\_state\`)       |

       |                                |                                   |

       | \------ 5\. end\_turn \-----------\> |                                   |

       |                                | \-- (Validates submove count \= N)  |

       |                                | \-- (Validates King safety)        |

       |                                |                                   |

       |                                | \=== IF VALID: \=================== |

       |                                | \------ 6a. Persist Events \------\> |

       |                                | \<----- 6b. Commit Success \------- |

       | \<--- 7\. turn\_committed \--------| \-- (Promotes staged \-\> committed) |

       |        (Broadcast to room)     | \-- (Swaps active player turn)     |

       |                                |                                   |

       |                                | \=== IF INVALID (King in Check): \= |

       | \<--- 8\. turn\_rejected \---------|                                   |

       |        (Prompt local rollback) | \-- (Clears \`staged\_state\`)        |

---

# **5\. Implementation Roadmap & Milestones**

\+-----------------------------------------------------------------------------------+

| SATURDAY MORNING: Phase 1 \- Backend Core Architecture                             |

| \- Setup Phoenix, Ecto, PostgreSQL schemas (games, game\_events)                    |

| \- Implement Game Engine GenServer, DynamicSupervisor, Registry                    |

| \- Define initial board state and core event structures                            |

\+-----------------------------------------------------------------------------------+

                                          |

                                          v

\+-----------------------------------------------------------------------------------+

| SATURDAY AFTERNOON: Phase 2 \- React Frontend & Realtime Socket Integration        |

| \- React landing page, room creation, and invite routing (/game/:id)               |

| \- Connect Phoenix Channel client & bind socket lifecycle events                   |

\+-----------------------------------------------------------------------------------+

                                          |

                                          v

\+-----------------------------------------------------------------------------------+

| SATURDAY EVENING: Phase 3 \- Custom Canvas Board Engine                            |

| \- Konva.js 8x8 grid rendering & coordinate projection math                        |

| \- Draggable piece layer, drop targets, and snapping mechanics                     |

\+-----------------------------------------------------------------------------------+

                                          |

                                          v

\+-----------------------------------------------------------------------------------+

| SUNDAY MORNING: Phase 4 \- Game Logic & Card Integration                           |

| \- Server-side deck shuffling & weighted drawing algorithms                        |

| \- Sub-move staging engine, restoration drops, and King safety validator           |

\+-----------------------------------------------------------------------------------+

                                          |

                                          v

\+-----------------------------------------------------------------------------------+

| SUNDAY AFTERNOON: Phase 5 \- Polish, End-to-End Validation & Deployment            |

| \- Turn rollback UI controls & failure state animations                            |

| \- Checkmate evaluation & game-over triggers                                       |

| \- Railway infrastructure deployment & full multiplayer dry-runs                   |

\+-----------------------------------------------------------------------------------+

## **Phase 1: Backend Foundation (Saturday Morning)**

* **Goal:** Establish core database schemas, process architecture, and state boundaries.  
* **Deliverables:**  
  * Initialized Phoenix application stripped of unnecessary HTML defaults (`--no-html --no-assets` or standalone API mode with React frontend SPA).  
  * Ecto migrations for `games` and `game_events`.  
  * `UnoChess.GameEngine.Server` GenServer holding state: `{committed_board, staged_board, deck, active_player, remaining_submoves}`.  
  * Registration pipeline utilizing `Registry.UnoChess.GameSessions`.

## **Phase 2: React Lobby & Routing (Saturday Afternoon)**

* **Goal:** Build the client entry points, game creation API, and socket connection infrastructure.  
* **Deliverables:**  
  * React SPA shell featuring landing page, dynamic game creation, and static rules visualizer.  
  * Route parameterization for `/game/:room_code`.  
  * Channel client integration hooks (`useGameSocket`) handling reconnects and status sync.

## **Phase 3: Custom Canvas Board (Saturday Evening)**

* **Goal:** Construct a high-performance interactive board via Konva.js.  
* **Deliverables:**  
  * Pure 2D canvas board drawing responsive to container dimensions.  
  * Sprite mapping for piece sets with layer-isolated drag-and-drop support.  
  * Grid-snapping math mapping mouse coordinates \$(x, y)\$ to algebraic notation (e.g., `e4`).

## **Phase 4: Game Logic & Uno Deck Integration (Sunday Morning)**

* **Goal:** Connect card mechanics, turn staging, piece restoration, and rules validation.  
* **Deliverables:**  
  * Weighted deck generation algorithm with automatic reshuffling when empty.  
  * Staging system allowing sequential intermediate moves on the frontend, verified by the backend.  
  * Graveyard UI drop zones enabling restoration placement restricted to home ranks (1–4 for White, 5–8 for Black).  
  * End-of-turn atomic validator inspecting final state for illegal check configurations.

## **Phase 5: Polish & Deployment (Sunday Afternoon)**

* **Goal:** Refine edge cases, deploy to cloud infrastructure, and execute test matches.  
* **Deliverables:**  
  * Rollback animations when a multi-move turn fails validation or leaves King in check.  
  * Game-over modal triggered on checkmate or opponent disconnection.  
  * Single-replica Railway deployment connected to managed Postgres instance.  
  * End-to-end integration testing across desktop and mobile browsers.

