import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/erlang_supervisor as sup

@external(erlang, "supervisor", "which_children")
fn erlang_which_children(sup_ref: Pid) -> Dynamic

@external(erlang, "supervisor", "get_childspec")
fn erlang_get_childspec(sup_ref: Pid, id: Dynamic) -> Result(Dynamic, Dynamic)

fn actor_child(name name, init init, loop loop) -> sup.ChildBuilder {
  sup.worker_child(name, fn() {
    let spec = actor.Spec(init: init, init_timeout: 10, loop: loop)
    let assert Ok(subject) = actor.start_spec(spec)
    Ok(process.subject_owner(subject))
  })
}

// A child that sends their name back to the test process during
// initialisation so that we can tell they (re)started
fn init_notifier_child(
  subject: Subject(#(String, Pid)),
  name: String,
) -> sup.ChildBuilder {
  actor_child(
    name: name,
    init: fn() {
      process.send(subject, #(name, process.self()))
      actor.Ready(name, process.new_selector())
    },
    loop: fn(_msg, state) { actor.continue(state) },
  )
}

fn failing_child(name: String) -> sup.ChildBuilder {
  actor_child(
    name: name,
    init: fn() { actor.Failed(name) },
    loop: fn(_msg, _state) { panic as "failed child should not loop" },
  )
}

pub fn one_for_one_test() {
  let subject = process.new_subject()

  let assert Ok(supervisor) =
    sup.new(sup.OneForOne)
    |> sup.restart_tolerance(3, 5)
    |> sup.add(init_notifier_child(subject, "1"))
    |> sup.add(init_notifier_child(subject, "2"))
    |> sup.add(init_notifier_child(subject, "3"))
    |> sup.start_link

  // Assert children have started
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown first child and assert only it restarts
  process.kill(p1)
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Shutdown second child and assert only it restarts
  process.kill(p2)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Start new child
  let assert Ok(_p4) =
    sup.start_child(supervisor, init_notifier_child(subject, "4"))

  // Assert new child has started
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown new child and assert only it restarts
  process.kill(p4)

  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Assert that we cannot restart a child before it is terminated
  let assert Error(sup.ChildRunning) = sup.restart_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)

  // Terminate third child and assert it is not restarting
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)

  // Restart the previously terminated child and assert
  // only it is restarting
  let assert Ok(_) = sup.restart_child(supervisor, "3")
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)

  // Asserting that we cannot delete a child that is running
  // This test sucks, it should test for sup.ChildRunning
  // but the erlang delete_child function return is annoying
  let assert Error(sup.UnknownError("deletion failed")) =
    sup.delete_child(supervisor, "3")

  // Terminating and deleting a child
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)
  let assert Ok(_) = sup.delete_child(supervisor, "3")

  let assert True =
    sup.count_children(supervisor)
    == [sup.Specs(3), sup.Active(3), sup.Supervisors(0), sup.Workers(3)]

  let supervisor_pid = sup.get_pid(supervisor)
  let assert True = process.is_alive(supervisor_pid)
  process.send_exit(supervisor_pid)
}

pub fn rest_for_one_test() {
  let subject = process.new_subject()

  let assert Ok(supervisor) =
    sup.new(sup.RestForOne)
    |> sup.restart_tolerance(4, 5)
    |> sup.add(init_notifier_child(subject, "1"))
    |> sup.add(init_notifier_child(subject, "2"))
    |> sup.add(init_notifier_child(subject, "3"))
    |> sup.start_link

  // Assert children have started
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", _p2)) = process.receive(subject, 10)
  let assert Ok(#("3", _p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown first child and assert all restart
  process.kill(p1)
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Shutdown second child and following restart
  process.kill(p2)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Start new child
  let assert Ok(_p4) =
    sup.start_child(supervisor, init_notifier_child(subject, "4"))

  // Assert new child has started
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown new child and assert only it restarts
  process.kill(p4)

  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Shutdown third child and following restart
  process.kill(p3)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Assert that we cannot restart a child before it is terminated
  let assert Error(sup.ChildRunning) = sup.restart_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)

  // Terminate third child and assert it is not restarting
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)

  // Restart the previously terminated child and assert
  // only it restarts (manual restart overrides strategy)
  let assert Ok(_) = sup.restart_child(supervisor, "3")
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Asserting that we cannot delete a child that is running
  // This test sucks, it should test for sup.ChildRunning
  // but the erlang delete_child function return is annoying
  let assert Error(sup.UnknownError("deletion failed")) =
    sup.delete_child(supervisor, "3")

  // Terminating and deleting a child
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)
  let assert Ok(_) = sup.delete_child(supervisor, "3")

  let assert True =
    sup.count_children(supervisor)
    == [sup.Specs(3), sup.Active(3), sup.Supervisors(0), sup.Workers(3)]

  let supervisor_pid = sup.get_pid(supervisor)
  let assert True = process.is_alive(supervisor_pid)
  process.send_exit(supervisor_pid)
}

pub fn one_for_all_test() {
  let subject = process.new_subject()

  let assert Ok(supervisor) =
    sup.new(sup.OneForAll)
    |> sup.restart_tolerance(4, 5)
    |> sup.add(init_notifier_child(subject, "1"))
    |> sup.add(init_notifier_child(subject, "2"))
    |> sup.add(init_notifier_child(subject, "3"))
    |> sup.start_link

  // Assert children have started
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", _p2)) = process.receive(subject, 10)
  let assert Ok(#("3", _p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown first child and all restart
  process.kill(p1)
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Shutdown second child and all restart
  process.kill(p2)
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Start new child
  let assert Ok(_p4) =
    sup.start_child(supervisor, init_notifier_child(subject, "4"))

  // Assert new child has started
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown new child and all restart
  process.kill(p4)

  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Shutdown third child and all restart
  process.kill(p3)
  let assert Ok(#("1", p1)) = process.receive(subject, 10)
  let assert Ok(#("2", p2)) = process.receive(subject, 10)
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Ok(#("4", p4)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Assert that we cannot restart a child before it is terminated
  let assert Error(sup.ChildRunning) = sup.restart_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)

  // Terminate third child and assert it is not restarting
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)

  // Restart the previously terminated child and assert
  // only it restarts (manual restart overrides strategy)
  let assert Ok(_) = sup.restart_child(supervisor, "3")
  let assert Ok(#("3", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 100)
  let assert True = process.is_alive(p3)
  let assert True = process.is_alive(p4)

  // Asserting that we cannot delete a child that is running
  // This test sucks, it should test for sup.ChildRunning
  // but the erlang delete_child function return is annoying
  let assert Error(sup.UnknownError("deletion failed")) =
    sup.delete_child(supervisor, "3")

  // Terminating and deleting a child
  let assert Ok(_) = sup.terminate_child(supervisor, "3")
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)
  let assert Ok(_) = sup.delete_child(supervisor, "3")

  let assert True =
    sup.count_children(supervisor)
    == [sup.Specs(3), sup.Active(3), sup.Supervisors(0), sup.Workers(3)]

  let supervisor_pid = sup.get_pid(supervisor)
  let assert True = process.is_alive(supervisor_pid)
  process.send_exit(supervisor_pid)
}

pub fn simple_one_for_one_test() {
  let subject = process.new_subject()

  let assert Ok(supervisor) =
    init_notifier_child(subject, "0")
    |> sup.simple_new
    |> sup.start_link

  // Assert no child has yet started
  let assert Error(_) = process.receive(subject, 100)

  // Count children
  let assert True =
    sup.count_children(supervisor)
    == [sup.Specs(1), sup.Active(0), sup.Supervisors(0), sup.Workers(0)]

  // Start one child
  let assert Ok(_p1) = sup.simple_start_child(supervisor, [])

  // Assert child was started

  let assert Ok(#("0", p1)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Start other children
  let assert Ok(_p2) = sup.simple_start_child(supervisor, [])
  let assert Ok(_p3) = sup.simple_start_child(supervisor, [])

  // Assert other children were started

  let assert Ok(#("0", p2)) = process.receive(subject, 10)
  let assert Ok(#("0", p3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Shutdown first child and assert only it restarts
  process.kill(p1)
  let assert Ok(#("0", p1)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Shutdown second child and assert only it restarts
  process.kill(p2)
  let assert Ok(#("0", p2)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
  let assert True = process.is_alive(p2)
  let assert True = process.is_alive(p3)

  // Terminate third child and assert it is not restarting
  let assert Ok(_) = sup.simple_terminate_child(supervisor, p3)
  let assert Error(Nil) = process.receive(subject, 100)
  let assert False = process.is_alive(p3)

  let supervisor_pid = sup.get_pid(supervisor)
  let assert True = process.is_alive(supervisor_pid)
  process.send_exit(supervisor_pid)
}

pub fn start_supervisor_child_test() {
  let health_subject = process.new_subject()
  let supervisor_started_subject = process.new_subject()
  let supervisor_failed_subject = process.new_subject()

  // Create the ChildBuilders for the supervisor children
  let sub_supervisor_builder_0 =
    sup.new(sup.OneForOne)
    |> sup.add(init_notifier_child(health_subject, "00"))
    |> sup.add(init_notifier_child(health_subject, "01"))
    |> sup.add(init_notifier_child(health_subject, "02"))
    |> sup.supervisor_child("0", fn(new_supervisor) {
      process.send(health_subject, #("0", sup.get_pid(new_supervisor)))
      process.send(supervisor_started_subject, #("sup0", new_supervisor))
    })

  let sub_supervisor_builder_1 =
    sup.new(sup.OneForOne)
    |> sup.add(init_notifier_child(health_subject, "10"))
    |> sup.add(init_notifier_child(health_subject, "11"))
    |> sup.add(init_notifier_child(health_subject, "12"))
    |> sup.supervisor_child("1", fn(new_supervisor) {
      process.send(health_subject, #("1", sup.get_pid(new_supervisor)))
      process.send(supervisor_started_subject, #("sup1", new_supervisor))
    })

  // Start top level supervisor
  // Verify if supervisor child added before start_link
  // works correctly
  let assert Ok(supervisor) =
    sup.new(sup.OneForAll)
    |> sup.add(sub_supervisor_builder_0)
    |> sup.start_link

  let assert Ok(#("00", _p00)) = process.receive(health_subject, 100)
  let assert Ok(#("01", _p01)) = process.receive(health_subject, 100)
  let assert Ok(#("02", _p02)) = process.receive(health_subject, 100)
  let assert Ok(#("0", _p0)) = process.receive(health_subject, 100)
  let assert Error(_) = process.receive(health_subject, 100)
  let assert Ok(#("sup0", _sub_supervisor_0)) =
    process.receive(supervisor_started_subject, 100)
  let assert Error(_) = process.receive(supervisor_started_subject, 100)

  // Check if supervisor children added through
  // `start_supervisor_child` work correctly
  let assert Ok(_sub_supervisor_1_pid) =
    sup.start_child(supervisor, sub_supervisor_builder_1)

  let assert Ok(#("10", _p10)) = process.receive(health_subject, 100)
  let assert Ok(#("11", _p11)) = process.receive(health_subject, 100)
  let assert Ok(#("12", _p12)) = process.receive(health_subject, 100)
  let assert Ok(#("1", _p1)) = process.receive(health_subject, 100)
  let assert Error(_) = process.receive(health_subject, 100)
  let assert Ok(#("sup1", _sub_supervisor_1)) =
    process.receive(supervisor_started_subject, 100)
  let assert Error(_) = process.receive(supervisor_started_subject, 100)
}
