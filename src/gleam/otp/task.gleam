//// A task is a kind of process that performs a single task and then shuts
//// down. Commonly tasks are used to convert sequential code into concurrent
//// code by performing computation in another process.
////
//// ```gleam
//// let task = task.async(fn() { do_some_work() })
//// let value = do_some_other_work()
//// value + task.await(task, 100)
//// ```
////
//// Tasks spawned with async can be awaited on by their caller process (and
//// only their caller) as shown in the example above. They are implemented by
//// spawning a process that sends a message to the caller once the given
//// computation is performed.
////
//// There are some important things to consider when using tasks:
////
//// 1. If you are using async tasks, you must await a reply as they are always
////    sent. If you do not need a reply from an async operation, look at using 
////    the `gleam/erlang/process` module's `start` function instead.
////
//// 2. Tasks link the caller and the spawned process. This means that,
////    if the caller crashes, the task will crash too and vice-versa. This is
////    on purpose: if the process meant to receive the result no longer
////    exists, there is no purpose in completing the computation.
////
//// 3. A task's callback function must complete by returning or panicking.
////    It must not `exit` with the reason "normal".
////
//// This module is inspired by Elixir's [Task module][1].
////
//// [1]: https://hexdocs.pm/elixir/master/Task.html
////

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/function
import gleam/option.{type Option, None, Some}

pub opaque type Task(value) {
  Task(owner: Pid, pid: Pid, subject: Subject(value))
}

// TODO: test
/// Spawn a task process that calls a given function in order to perform some
/// work. The result of this function is send back to the parent and can be
/// received using the `await` function.
///
/// See the top level module documentation for more information on async/await.
///
pub fn async(work: fn() -> value) -> Task(value) {
  let owner = process.self()
  let subject = process.new_subject()
  let pid =
    process.start(linked: True, running: fn() { process.send(subject, work()) })
  Task(owner: owner, pid: pid, subject: subject)
}

pub type AwaitError {
  Timeout
  Exit(reason: Dynamic)
}

// We can only wait on a task if we are the owner of it so crash if we are
// waiting on a task we don't own.
fn assert_owner(task: Task(a)) -> Nil {
  let self = process.self()
  case task.owner == self {
    True -> Nil
    False ->
      process.send_abnormal_exit(
        self,
        "awaited on a task that does not belong to this process",
      )
  }
}

// TODO: test
/// Wait for the value computed by a task.
///
/// If the a value is not received before the timeout has elapsed then an error
/// is returned.
///
pub fn try_await(task: Task(value), timeout: Int) -> Result(value, AwaitError) {
  assert_owner(task)
  let selector =
    process.new_selector()
    |> process.selecting(task.subject, function.identity)
  case process.select(selector, timeout) {
    // The task process has sent back a value
    Ok(x) -> Ok(x)

    // The task process is alive but has not sent a value yet
    Error(Nil) -> Error(Timeout)
  }
}

/// Wait for the value computed by a task.
///
/// If the a value is not received before the timeout has elapsed or if the
/// task process crashes then this function crashes.
///
pub fn await(task: Task(value), timeout: Int) -> value {
  let assert Ok(value) = try_await(task, timeout)
  value
}

/// Get the `Pid` for a task.
///
pub fn pid(task: Task(value)) -> Pid {
  task.pid
}

@deprecated("Use await_forever")
pub fn try_await_forever(task: Task(value)) -> Result(value, AwaitError) {
  assert_owner(task)
  let selector =
    process.new_selector()
    |> process.selecting(task.subject, function.identity)
  case process.select_forever(selector) {
    // The task process has sent back a value
    x -> Ok(x)
  }
}

/// Wait endlessly for the value computed by a task.
///
/// Be Careful! Like `try_await_forever`, this function does not return until
/// there is a value to receive.
///
/// If the task process crashes then this function crashes.
///
pub fn await_forever(task: Task(value)) -> value {
  assert_owner(task)
  let selector =
    process.new_selector()
    |> process.selecting(task.subject, function.identity)
  process.select_forever(selector)
}

type Message2(t1, t2) {
  M2FromSubject1(t1)
  M2FromSubject2(t2)
  M2Timeout
}

/// Wait for the values computed by multiple tasks.
///
/// For each task, if the a value is not received before the timeout has
/// elapsed then an error is returned.
///
pub fn try_await2(
  task1: Task(t1),
  task2: Task(t2),
  timeout: Int,
) -> #(Result(t1, AwaitError), Result(t2, AwaitError)) {
  assert_owner(task1)
  assert_owner(task2)

  let timeout_subject = process.new_subject()
  let timer = process.send_after(timeout_subject, timeout, M2Timeout)

  process.new_selector()
  |> process.selecting(task1.subject, M2FromSubject1)
  |> process.selecting(task2.subject, M2FromSubject2)
  |> process.selecting(timeout_subject, function.identity)
  |> try_await2_loop(None, None, timer)
}

fn try_await2_loop(
  selector: Selector(Message2(t1, t2)),
  t1: Option(Result(t1, AwaitError)),
  t2: Option(Result(t2, AwaitError)),
  timeout: process.Timer,
) -> #(Result(t1, AwaitError), Result(t2, AwaitError)) {
  case t1, t2 {
    Some(t1), Some(t2) -> #(t1, t2)

    _, _ -> {
      case process.select_forever(selector) {
        // The task process has sent back a value
        M2FromSubject1(x) -> {
          let t1 = Some(Ok(x))
          try_await2_loop(selector, t1, t2, timeout)
        }
        M2FromSubject2(x) -> {
          let t2 = Some(Ok(x))
          try_await2_loop(selector, t1, t2, timeout)
        }

        M2Timeout -> {
          #(
            option.unwrap(t1, Error(Timeout)),
            option.unwrap(t2, Error(Timeout)),
          )
        }
      }
    }
  }
}

type Message3(t1, t2, t3) {
  M3FromSubject1(t1)
  M3FromSubject2(t2)
  M3FromSubject3(t3)
  M3Timeout
}

/// Wait for the values computed by multiple tasks.
///
/// For each task, if the a value is not received before the timeout has
/// elapsed then an error is returned.
///
pub fn try_await3(
  task1: Task(t1),
  task2: Task(t2),
  task3: Task(t3),
  timeout: Int,
) -> #(Result(t1, AwaitError), Result(t2, AwaitError), Result(t3, AwaitError)) {
  assert_owner(task1)
  assert_owner(task2)
  assert_owner(task3)

  let timeout_subject = process.new_subject()
  let timer = process.send_after(timeout_subject, timeout, M3Timeout)

  process.new_selector()
  |> process.selecting(task1.subject, M3FromSubject1)
  |> process.selecting(task2.subject, M3FromSubject2)
  |> process.selecting(task3.subject, M3FromSubject3)
  |> process.selecting(timeout_subject, function.identity)
  |> try_await3_loop(None, None, None, timer)
}

fn try_await3_loop(
  selector: Selector(Message3(t1, t2, t3)),
  t1: Option(Result(t1, AwaitError)),
  t2: Option(Result(t2, AwaitError)),
  t3: Option(Result(t3, AwaitError)),
  timeout: process.Timer,
) -> #(Result(t1, AwaitError), Result(t2, AwaitError), Result(t3, AwaitError)) {
  case t1, t2, t3 {
    Some(t1), Some(t2), Some(t3) -> #(t1, t2, t3)

    _, _, _ -> {
      case process.select_forever(selector) {
        // The task process has sent back a value
        M3FromSubject1(x) -> {
          let t1 = Some(Ok(x))
          try_await3_loop(selector, t1, t2, t3, timeout)
        }
        M3FromSubject2(x) -> {
          let t2 = Some(Ok(x))
          try_await3_loop(selector, t1, t2, t3, timeout)
        }
        M3FromSubject3(x) -> {
          let t3 = Some(Ok(x))
          try_await3_loop(selector, t1, t2, t3, timeout)
        }

        M3Timeout -> {
          #(
            option.unwrap(t1, Error(Timeout)),
            option.unwrap(t2, Error(Timeout)),
            option.unwrap(t3, Error(Timeout)),
          )
        }
      }
    }
  }
}

type Message4(t1, t2, t3, t4) {
  M4FromSubject1(t1)
  M4FromSubject2(t2)
  M4FromSubject3(t3)
  M4FromSubject4(t4)
  M4Timeout
}

/// Wait for the values computed by multiple tasks.
///
/// For each task, if the a value is not received before the timeout has
/// elapsed then an error is returned.
///
pub fn try_await4(
  task1: Task(t1),
  task2: Task(t2),
  task3: Task(t3),
  task4: Task(t4),
  timeout: Int,
) -> #(
  Result(t1, AwaitError),
  Result(t2, AwaitError),
  Result(t3, AwaitError),
  Result(t4, AwaitError),
) {
  assert_owner(task1)
  assert_owner(task2)
  assert_owner(task3)

  let timeout_subject = process.new_subject()
  let timer = process.send_after(timeout_subject, timeout, M4Timeout)

  process.new_selector()
  |> process.selecting(task1.subject, M4FromSubject1)
  |> process.selecting(task2.subject, M4FromSubject2)
  |> process.selecting(task3.subject, M4FromSubject3)
  |> process.selecting(task4.subject, M4FromSubject4)
  |> process.selecting(timeout_subject, function.identity)
  |> try_await4_loop(None, None, None, None, timer)
}

fn try_await4_loop(
  selector: Selector(Message4(t1, t2, t3, t4)),
  t1: Option(Result(t1, AwaitError)),
  t2: Option(Result(t2, AwaitError)),
  t3: Option(Result(t3, AwaitError)),
  t4: Option(Result(t4, AwaitError)),
  timeout: process.Timer,
) -> #(
  Result(t1, AwaitError),
  Result(t2, AwaitError),
  Result(t3, AwaitError),
  Result(t4, AwaitError),
) {
  case t1, t2, t3, t4 {
    Some(t1), Some(t2), Some(t3), Some(t4) -> #(t1, t2, t3, t4)

    _, _, _, _ -> {
      case process.select_forever(selector) {
        // The task process has sent back a value
        M4FromSubject1(x) -> {
          let t1 = Some(Ok(x))
          try_await4_loop(selector, t1, t2, t3, t4, timeout)
        }
        M4FromSubject2(x) -> {
          let t2 = Some(Ok(x))
          try_await4_loop(selector, t1, t2, t3, t4, timeout)
        }
        M4FromSubject3(x) -> {
          let t3 = Some(Ok(x))
          try_await4_loop(selector, t1, t2, t3, t4, timeout)
        }
        M4FromSubject4(x) -> {
          let t4 = Some(Ok(x))
          try_await4_loop(selector, t1, t2, t3, t4, timeout)
        }

        M4Timeout -> {
          #(
            option.unwrap(t1, Error(Timeout)),
            option.unwrap(t2, Error(Timeout)),
            option.unwrap(t3, Error(Timeout)),
            option.unwrap(t4, Error(Timeout)),
          )
        }
      }
    }
  }
}
