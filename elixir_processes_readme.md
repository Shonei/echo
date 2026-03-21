# Elixir Processes: Spawning, Linking, and Lifecycles

This guide explains how Elixir (running on the Erlang VM, the BEAM) handles processes, how they interact, and the different approaches to starting them based on your use case. 

For the official, exhaustive details, always refer to the [Elixir Process Documentation](https://hexdocs.pm/elixir/Process.html).

---

## 1. The BEAM Process Model Overview

In Elixir, **all code runs inside processes**. These are not heavy Operating System processes or OS threads; they are extremely lightweight, isolated execution threads managed entirely by the Erlang VM. You can run hundreds of thousands of them concurrently on a single machine.
Each process has its own memory (garbage collected independently) and communicates with others strictly through message passing.

---

## 2. Linking and Process Termination

When you start a new process, the most crucial distinction is whether the new process is **Linked** or **Unlinked** to the process that created it.

### Unlinked Processes (e.g., `spawn/1`)
When process A spawns process B *without* a link, they are entirely independent.
- If A dies, B keeps running.
- If B dies, A keeps running.
- **Example Usage:** "Fire and forget" background work that is non-critical.

### Linked Processes (e.g., `spawn_link/1`)
When process A spawns process B *with* a link, a bidirectional bond is formed.
If one process terminates, it sends an **Exit Signal** to the linked process. The behavior depends on the *reason* for termination:
1. **Normal Termination (`:normal`)**: If a process simply finishes its final line of code, it exits with reason `:normal`. By default, linked processes **ignore** normal exit signals.
2. **Abnormal Termination (Crash)**: If a process crashes (e.g., raises an exception, division by zero), it exits with a non-normal reason. The linked process receives this signal and **crashes as well**. This cascading failure is exactly what powers Elixir's "Let it crash" philosophy.

*Note: A process can defend itself against cascading crashes by "trapping exits" using `Process.flag(:trap_exit, true)`. Instead of crashing, it receives a message `{:EXIT, from_pid, reason}`.*

---

## 3. Different Ways to Start Processes

Elixir provides several abstractions over the raw `spawn` functions, from the most basic to the most structured.

### 3.1 Raw Spawn (`spawn` vs `spawn_link`)
The most primitive way to start a process. It takes a function and runs it.
```elixir
# Unlinked
pid1 = spawn(fn -> IO.puts("Running independently") end)

# Linked 
pid2 = spawn_link(fn -> IO.puts("Tied to parent") end)
```
- **Docs:** [Kernel.spawn/1](https://hexdocs.pm/elixir/Kernel.html#spawn/1)

### 3.2 The `Task` Module
Tasks are slightly higher-level primitives meant for executing one-off background work or retrieving async results.

* **`Task.start/1` (Unlinked):** Great for fire-and-forget background jobs that don't return a value and shouldn't crash the parent.
* **`Task.async/1` (Linked & Monitored):** Used when you want to compute a value asynchronously and wait for it later using `Task.await/1`. If `Task.async` crashes, your parent caller crashes with it.
```elixir
# Unlinked background job
Task.start(fn -> process_image(image) end)

# Linked, expecting a return value
task = Task.async(fn -> calculate_heavy_math() end)
result = Task.await(task)
```
- **Docs:** [Task](https://hexdocs.pm/elixir/Task.html)

### 3.3 The `GenServer` Module
A `GenServer` (Generic Server) is a process that keeps state, handles synchronous (`call`) and asynchronous (`cast`) requests, and lives for a long time.

* **`GenServer.start/3` (Unlinked):** Process is started but not tied to the caller. Very rarely used in production applications.
* **`GenServer.start_link/3` (Linked):** The standardized way to start a server. It links the caller process to the new GenServer.
```elixir
{:ok, pid} = GenServer.start_link(MyCache, %{}, name: :my_cache_server)
```
- **Docs:** [GenServer](https://hexdocs.pm/elixir/GenServer.html)

---

## 4. Why We Need Supervisors

If you rely purely on `spawn_link` or `Task.async`, a crash in one place will bring down everything linked to it. If you rely purely on `spawn` or `Task.start`, crashed processes simply disappear and are gone forever (Orphan processes).

**[Supervisors](https://hexdocs.pm/elixir/Supervisor.html)** solve this problem. A Supervisor is a specialized process whose sole responsibility is monitoring other processes (its children) and **restarting them if they crash**.

When you write professional Elixir code, you almost always start processes by attaching them to a Supervisor tree, rather than calling `start_link` or `spawn` directly.

### Static Supervision (`Supervisor`)
Used when you know the exact processes your app needs at startup (e.g., your database connection pool, your Phoenix web server, a central cache).
```elixir
children = [
  MyApp.Repo,
  MyApp.Web.Endpoint,
  {MyCacheServer, []}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### Dynamic Supervision (`DynamicSupervisor`)
Perfect for processes that are created on-demand, like starting a unique worker process for every HTTP request (as described in your original scenario!) or for every user that logs into a chat room. By attaching your dynamic `proc1` to a DynamicSupervisor, it runs independently from the HTTP request taking it, but still gets restarted if it encounters a transient error.
```elixir
# Inside your HTTP Handler:
{:ok, pid} = DynamicSupervisor.start_child(
  MyApp.WorkerSupervisor,
  {MyWorker, %{user_id: 123}}
)
```
- **Docs:** [DynamicSupervisor](https://hexdocs.pm/elixir/DynamicSupervisor.html), [Task.Supervisor](https://hexdocs.pm/elixir/Task.Supervisor.html) (a specialized dynamic supervisor just for tasks).

---

## 5. Summary Matrix: What to use?

| Use Case | Recommended Tool | Link Status to Caller |
| :--- | :--- | :--- |
| **Fire and forget** background job (no result needed) | `Task.Supervisor.start_child/2` (or `Task.start/1`) | Unlinked |
| **Compute parallel operation** and wait for result | `Task.async/1` + `Task.await/1` | Linked |
| **Long-lived process** with state (e.g. Cache) | `GenServer.start_link/3` (Under a static Supervisor) | Linked (To Supervisor) |
| **On-demand background workers** (e.g. 1 per HTTP req) | `DynamicSupervisor.start_child/2` | Linked (To Supervisor) |
