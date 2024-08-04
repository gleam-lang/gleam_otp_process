import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervisor.{add, returning, worker}
import gleeunit/should

pub fn supervisor_test() {
  let subject = process.new_subject()

  // Children send their name back to the test process during
  // initialisation so that we can tell they (re)started
  let child =
    worker(fn(name) {
      actor.start_spec(
        actor.Spec(
          init: fn() {
            process.send(subject, #(name, process.self()))
            actor.Ready(name, process.new_selector())
          },
          init_timeout: 10,
          loop: fn(_msg, state) { actor.continue(state) },
        ),
      )
    })

  // Each child returns the next name, which is their name + 1
  let child =
    child
    |> returning(fn(name, _subject) { name + 1 })

  supervisor.start_spec(
    supervisor.Spec(
      argument: 1,
      frequency_period: 1,
      max_frequency: 5,
      init: fn(children) {
        children
        |> add(child)
        |> add(child)
        |> add(child)
      },
    ),
  )
  |> should.be_ok

  // Assert children have started
  let assert Ok(#(1, pid1)) = process.receive(subject, 10)
  let assert Ok(#(2, pid2)) = process.receive(subject, 10)
  let assert Ok(#(3, pid3)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Kill first child an assert they all restart
  process.kill(pid1)
  let assert Ok(#(1, p1)) = process.receive(subject, 10)
  let assert Ok(#(2, p2)) = process.receive(subject, 10)
  let assert Ok(#(3, _)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)

  // Ensure that the original processes are dead
  should.be_false(process.is_alive(pid1))
  should.be_false(process.is_alive(pid2))
  should.be_false(process.is_alive(pid3))

  // Kill second child an assert the following children restart
  process.kill(p2)
  let assert Ok(#(2, _)) = process.receive(subject, 10)
  let assert Ok(#(3, _)) = process.receive(subject, 10)
  let assert Error(Nil) = process.receive(subject, 10)
  let assert True = process.is_alive(p1)
}
