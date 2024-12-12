//// Bindings to Erlang/OTP's `supervisor` module.
////
//// For further detail see the Erlang documentation:
//// <https://www.erlang.org/doc/apps/stdlib/supervisor.html>.
////
//// # Example
////
//// ```gleam
//// import gleam/erlang/process.{type Pid}
//// import gleam/otp/static_supervisor as sup
//// 
//// pub fn start_supervisor() {
////   sup.new(sup.OneForOne)
////   |> sup.add(sup.worker_child("db", start_database_connection))
////   |> sup.add(sup.worker_child("workers", start_workers))
////   |> sup.add(sup.worker_child("web", start_http_server))
////   |> sup.start_link
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/result

pub opaque type Supervisor(kind) {
  Supervisor(pid: Pid)
}

pub type Strategy {
  /// If one child process terminates and is to be restarted, only that child
  /// process is affected. This is the default restart strategy.
  OneForOne

  /// If one child process terminates and is to be restarted, all other child
  /// processes are terminated and then all child processes are restarted.
  OneForAll

  /// If one child process terminates and is to be restarted, the 'rest' of the
  /// child processes (that is, the child processes after the terminated child
  /// process in the start order) are terminated. Then the terminated child
  /// process and all child processes after it are restarted.
  RestForOne

  SimpleOneForOne
}

/// A supervisor can be configured to automatically shut itself down with exit
/// reason shutdown when significant children terminate with the auto_shutdown
/// key in the above map.
pub type AutoShutdown {
  /// Automic shutdown is disabled. This is the default setting.
  ///
  /// With auto_shutdown set to never, child specs with the significant flag
  /// set to true are considered invalid and will be rejected.
  Never
  /// The supervisor will shut itself down when any significant child
  /// terminates, that is, when a transient significant child terminates
  /// normally or when a temporary significant child terminates normally or
  /// abnormally.
  AnySignificant
  /// The supervisor will shut itself down when all significant children have
  /// terminated, that is, when the last active significant child terminates.
  /// The same rules as for any_significant apply.
  AllSignificant
}

pub opaque type Builder(kind) {
  Builder(
    intensity: Int,
    period: Int,
    auto_shutdown: AutoShutdown,
    strategy: Strategy,
    children: List(ChildBuilder),
  )
}

pub type Simple

pub type Classic

const default_restart_intensity = 2

const default_restart_period = 5

pub fn new(strategy strategy: Strategy) -> Builder(Classic) {
  Builder(
    strategy: strategy,
    intensity: default_restart_intensity,
    period: default_restart_period,
    auto_shutdown: Never,
    children: [],
  )
}

pub fn simple_new(child: ChildBuilder) -> Builder(Simple) {
  Builder(
    strategy: SimpleOneForOne,
    intensity: default_restart_intensity,
    period: default_restart_period,
    auto_shutdown: Never,
    children: [child],
  )
}

/// To prevent a supervisor from getting into an infinite loop of child
/// process terminations and restarts, a maximum restart intensity is
/// defined using two integer values specified with keys intensity and
/// period in the above map. Assuming the values MaxR for intensity and MaxT
/// for period, then, if more than MaxR restarts occur within MaxT seconds,
/// the supervisor terminates all child processes and then itself. The
/// termination reason for the supervisor itself in that case will be
/// shutdown. 
///
/// Intensity defaults to 2 and period defaults to 5.
pub fn restart_tolerance(
  builder: Builder(either),
  intensity intensity: Int,
  period period: Int,
) -> Builder(either) {
  Builder(..builder, intensity: intensity, period: period)
}

/// A supervisor can be configured to automatically shut itself down with
/// exit reason shutdown when significant children terminate.
pub fn auto_shutdown(
  builder: Builder(either),
  value: AutoShutdown,
) -> Builder(either) {
  Builder(..builder, auto_shutdown: value)
}

/// Restart defines when a terminated child process must be restarted. 
pub type Restart {
  /// A permanent child process is always restarted.
  Permanent
  /// A transient child process is restarted only if it terminates abnormally,
  /// that is, with another exit reason than `normal`, `shutdown`, or
  /// `{shutdown,Term}`.
  Transient
  /// A temporary child process is never restarted (even when the supervisor's
  /// restart strategy is `RestForOne` or `OneForAll` and a sibling's death
  /// causes the temporary process to be terminated).
  Temporary
}

pub type ChildType {
  WorkerChild(
    /// The number of milliseconds the child is given to shut down. The
    /// supervisor tells the child process to terminate by calling
    /// `exit(Child,shutdown)` and then wait for an exit signal with reason
    /// shutdown back from the child process. If no exit signal is received
    /// within the specified number of milliseconds, the child process is
    /// unconditionally terminated using `exit(Child,kill)`.
    shutdown_ms: Int,
  )
  SupervisorChild
}

pub opaque type ChildBuilder {
  ChildBuilder(
    /// id is used to identify the child specification internally by the
    /// supervisor.
    ///
    /// Notice that this identifier on occations has been called "name". As far
    /// as possible, the terms "identifier" or "id" are now used but to keep
    /// backward compatibility, some occurences of "name" can still be found, for
    /// example in error messages.
    id: String,
    /// A function to call to start the child process.
    starter: fn() -> Result(Pid, Dynamic),
    /// When the child is to be restarted. See the `Restart` documentation for
    /// more.
    ///
    /// You most likely want the `Permanent` variant.
    restart: Restart,
    /// This defines if a child is considered significant for automatic
    /// self-shutdown of the supervisor.
    ///
    /// You most likely do not want to consider any children significant.
    ///
    /// This will be ignored if the supervisor auto shutdown is set to `Never`,
    /// which is the default.
    significant: Bool,
    /// Whether the child is a supervisor or not.
    child_type: ChildType,
  )
}

pub type LinkStartError {
  ErlangError(Dynamic)
  SimpleOneForOneMultipleChildrenError
}

pub fn start_link(
  builder: Builder(either),
) -> Result(Supervisor(either), LinkStartError) {
  let flags =
    dict.new()
    |> property("strategy", builder.strategy)
    |> property("intensity", builder.intensity)
    |> property("period", builder.period)
    |> property("auto_shutdown", builder.auto_shutdown)

  let children =
    builder.children |> list.reverse |> list.map(child_builder_to_erlang)

  use supervisor_pid <- result.map(
    erlang_start_link(#(flags, children))
    |> result.map_error(fn(erlang_error) { ErlangError(erlang_error) }),
  )
  Supervisor(supervisor_pid)
}

pub fn get_pid(supervisor: Supervisor(either)) -> Pid {
  supervisor.pid
}

pub fn start_child(
  supervisor: Supervisor(Classic),
  child_builder: ChildBuilder,
) -> Result(Pid, SupervisorError) {
  erlang_start_child(
    supervisor.pid,
    child_builder |> child_builder_to_erlang |> dynamic.from,
  )
}

pub fn simple_start_child(
  supervisor: Supervisor(Simple),
  args: List(Dynamic),
) -> Result(Pid, SupervisorError) {
  erlang_start_child(supervisor.pid, args |> dynamic.from)
}

pub type SupervisorError {
  AlreadyPresent
  AlreadyStart(Dynamic)
  SupervisorNotSimpleOneForOne
  SimpleOneForOneForbidden
  ChildNotFound
  ChildRunning
  ChildRestarting
  UnknownError(details: String)
}

pub fn delete_child(
  supervisor: Supervisor(Classic),
  id: String,
) -> Result(Nil, SupervisorError) {
  let deletion_result = erlang_delete_child(supervisor.pid, id |> dynamic.from)
  case deletion_result |> atom.from_dynamic {
    Error(_) -> Error(UnknownError("deletion failed"))
    Ok(_) -> Ok(Nil)
  }
}

pub fn restart_child(
  supervisor: Supervisor(Classic),
  id: String,
) -> Result(Pid, SupervisorError) {
  erlang_restart_child(supervisor.pid, id |> dynamic.from)
  |> result.map_error(fn(e) {
    case atom.from_dynamic(e) {
      Error(_) ->
        UnknownError(
          "failed to parse erlang's supervisor:restart_child/2 return to an atomic",
        )
      Ok(err_msg) ->
        case atom.to_string(err_msg) {
          "running" -> ChildRunning
          "restarting" -> ChildRestarting
          "not_found" -> ChildNotFound
          "simple_one_for_one" ->
            panic as "simple-one-for-one supervisors should already have been caught"
          other -> UnknownError(other)
        }
    }
  })
}

pub fn terminate_child(
  supervisor: Supervisor(Classic),
  id: String,
) -> Result(Nil, SupervisorError) {
  let termination_result =
    erlang_terminate_child(supervisor.pid, id |> dynamic.from)

  case
    termination_result
    |> atom.from_dynamic
  {
    Error(_) -> Error(ChildNotFound)
    Ok(_) -> Ok(Nil)
  }
}

pub fn simple_terminate_child(
  supervisor: Supervisor(Simple),
  child: Pid,
) -> Result(Nil, SupervisorError) {
  let termination_result =
    erlang_terminate_child(supervisor.pid, child |> dynamic.from)

  case
    termination_result
    |> atom.from_dynamic
  {
    Error(_) -> Error(ChildNotFound)
    Ok(_) -> Ok(Nil)
  }
}

/// Add a child to the supervisor.
pub fn add(builder: Builder(Classic), child: ChildBuilder) -> Builder(Classic) {
  Builder(..builder, children: [child, ..builder.children])
}

pub type Property {
  Specs(count: Int)
  Active(count: Int)
  Supervisors(count: Int)
  Workers(count: Int)
}

pub fn count_children(supervisor: Supervisor(either)) -> List(Property) {
  erlang_count_children(supervisor.pid)
}

/// A regular child that is not also a supervisor.
///
/// id is used to identify the child specification internally by the
/// supervisor.
/// Notice that this identifier on occations has been called "name". As far
/// as possible, the terms "identifier" or "id" are now used but to keep
/// backward compatibility, some occurences of "name" can still be found, for
/// example in error messages.
///
pub fn worker_child(
  id id: String,
  run starter: fn() -> Result(Pid, whatever),
) -> ChildBuilder {
  ChildBuilder(
    id: id,
    starter: fn() { starter() |> result.map_error(dynamic.from) },
    restart: Permanent,
    significant: False,
    child_type: WorkerChild(5000),
  )
}

/// A special child that is a supervisor itself.
///
/// id is used to identify the child specification internally by the
/// supervisor.
/// Notice that this identifier on occations has been called "name". As far
/// as possible, the terms "identifier" or "id" are now used but to keep
/// backward compatibility, some occurences of "name" can still be found, for
/// example in error messages.
///
pub fn supervisor_child(
  builder builder: Builder(either),
  id id: String,
  on_started starter: fn(Supervisor(either)) -> Nil,
) -> ChildBuilder {
  let starter: fn() -> Result(Pid, LinkStartError) = fn() {
    use sup <- result.map(start_link(builder))
    starter(sup)
    sup.pid
  }
  ChildBuilder(
    id: id,
    starter: fn() { starter() |> result.map_error(dynamic.from) },
    restart: Permanent,
    significant: False,
    child_type: SupervisorChild,
  )
}

/// This defines if a child is considered significant for automatic
/// self-shutdown of the supervisor.
///
/// You most likely do not want to consider any children significant.
///
/// This will be ignored if the supervisor auto shutdown is set to `Never`,
/// which is the default.
///
/// The default value for significance is `False`.
pub fn significant(child: ChildBuilder, significant: Bool) -> ChildBuilder {
  ChildBuilder(..child, significant: significant)
}

/// This defines the amount of milliseconds a child has to shut down before
/// being brutal killed by the supervisor.
///
/// If not set the default for a child is 5000ms.
///
/// This will be ignored if the child is a supervisor itself.
///
pub fn timeout(child: ChildBuilder, ms ms: Int) -> ChildBuilder {
  case child.child_type {
    WorkerChild(_) -> ChildBuilder(..child, child_type: WorkerChild(ms))
    _ -> child
  }
}

/// When the child is to be restarted. See the `Restart` documentation for
/// more.
///
/// The default value for restart is `Permanent`.
pub fn restart(child: ChildBuilder, restart: Restart) -> ChildBuilder {
  ChildBuilder(..child, restart: restart)
}

fn child_builder_to_erlang(child: ChildBuilder) -> Dict(Atom, Dynamic) {
  let mfa = #(
    atom.create_from_string("erlang"),
    atom.create_from_string("apply"),
    [dynamic.from(child.starter), dynamic.from([])],
  )

  let #(type_, shutdown) = case child.child_type {
    SupervisorChild -> #(
      atom.create_from_string("supervisor"),
      dynamic.from(atom.create_from_string("infinity")),
    )
    WorkerChild(timeout) -> #(
      atom.create_from_string("worker"),
      dynamic.from(timeout),
    )
  }

  dict.new()
  |> property("id", child.id)
  |> property("start", mfa)
  |> property("restart", child.restart)
  |> property("significant", child.significant)
  |> property("type", type_)
  |> property("shutdown", shutdown)
}

fn property(
  dict: Dict(Atom, Dynamic),
  key: String,
  value: anything,
) -> Dict(Atom, Dynamic) {
  dict.insert(dict, atom.create_from_string(key), dynamic.from(value))
}

// Callback used by the Erlang supervisor module.
@internal
pub fn init(start_data: Dynamic) -> Result(Dynamic, never) {
  Ok(start_data)
}

// Erlang bindings

@external(erlang, "supervisor", "start_child")
fn erlang_start_child(
  supervisor: Pid,
  child_spec_or_extra_args: Dynamic,
) -> Result(Pid, SupervisorError)

@external(erlang, "gleam_otp_external", "erlang_supervisor_start_link")
fn erlang_start_link(
  args: #(Dict(Atom, Dynamic), List(Dict(Atom, Dynamic))),
) -> Result(Pid, Dynamic)

// This should definitely not be returning a dynamic, but the actual
// return type is really annoying (it's an "ok" atom without a record)
// https://www.erlang.org/doc/apps/stdlib/supervisor.html#terminate_child/2
@external(erlang, "supervisor", "terminate_child")
fn erlang_terminate_child(supervisor: Pid, id_or_pid: Dynamic) -> Dynamic

// The return type could be improved
@external(erlang, "supervisor", "restart_child")
fn erlang_restart_child(supervisor: Pid, id: Dynamic) -> Result(Pid, Dynamic)

@external(erlang, "supervisor", "delete_child")
fn erlang_delete_child(supervisor: Pid, id: Dynamic) -> Dynamic

@external(erlang, "supervisor", "count_children")
fn erlang_count_children(sup_ref: Pid) -> List(Property)
