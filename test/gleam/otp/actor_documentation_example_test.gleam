//// If you update this file be sure to update the documentation in the actor
//// module which includes a copy of this.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub fn example_test() {
  // Start the actor with initial state of an empty list, and the
  // `handle_message` callback function (defined below).
  // We assert that it starts successfully.
  // 
  // In real-world Gleam OTP programs we would likely write a wrapper functions
  // called `start`, `push` `pop`, `shutdown` to start and interact with the
  // Actor. We are not doing that here for the sake of showing how the Actor 
  // API works.
  let assert Ok(actor) = actor.start([], handle_message)

  // We can send a message to the actor to push elements onto the stack.
  process.send(actor, Push("Joe"))
  process.send(actor, Push("Mike"))
  process.send(actor, Push("Robert"))

  // The `Push` message expects no response, these messages are sent purely for
  // the side effect of mutating the state held by the actor.
  //
  // We can also send the `Pop` message to take a value off of the actor's
  // stack. This message expects a response, so we use `process.call` to send a
  // message and wait until a reply is received.
  //
  // In this instance we are giving the actor 10 milliseconds to reply, if the
  // `call` function doesn't get a reply within this time it will panic and
  // crash the client process.
  let assert Ok("Robert") = process.call(actor, Pop, 10)
  let assert Ok("Mike") = process.call(actor, Pop, 10)
  let assert Ok("Joe") = process.call(actor, Pop, 10)

  // The stack is now empty, so if we pop again the actor replies with an error.
  let assert Error(Nil) = process.call(actor, Pop, 10)

  // Lastly, we can send a message to the actor asking it to shut down.
  process.send(actor, Shutdown)
}

// First step of implementing the stack Actor is to define the message type that
// it can receive.
//
// The type of the elements in the stack is no fixed so a type parameter is used
// for it instead of a concrete type such as `String` or `Int`.
pub type Message(element) {
  // The `Shutdown` message is used to tell the actor to stop.
  // It is the simplest message type, it contains no data.
  Shutdown

  // The `Push` message is used to add a new element to the stack.
  // It contains the item to add, the type of which is the `element`
  // parameterised type.
  Push(push: element)

  // The `Pop` message is used to remove an element from the stack.
  // It contains a `Subject`, which is used to send the response back to the
  // message sender. In this case the reply is of type `Result(element, Nil)`.
  Pop(reply_with: Subject(Result(element, Nil)))
}

// The last part is to implement the `handle_message` callback function.
//
// This function is called by the Actor each for each message it receives.
// Actor is single threaded only does one thing at a time, so it handles
// messages sequentially and one at a time, in the order they are received.
//
// The function takes the message and the current state, and returns a data
// structure that indicates what to do next, along with the new state.
fn handle_message(
  message: Message(e),
  stack: List(e),
) -> actor.Next(Message(e), List(e)) {
  case message {
    // For the `Shutdown` message we return the `actor.Stop` value, which causes
    // the actor to discard any remaining messages and stop.
    Shutdown -> actor.Stop

    // For the `Push` message we add the new element to the stack and return
    // `actor.Continue` with this new stack, causing the actor to process any
    // queued messages or wait for more.
    Push(value) -> {
      let new_state = [value, ..stack]
      actor.continue(new_state)
    }

    // For the `Pop` message we attempt to remove an element from the stack,
    // sending it or an error back to the caller, before continuing.
    Pop(client) ->
      case stack {
        [] -> {
          // When the stack is empty we can't pop an element, so we send an
          // error back.
          process.send(client, Error(Nil))
          actor.continue([])
        }

        [first, ..rest] -> {
          // Otherwise we send the first element back and use the remaining
          // elements as the new state.
          process.send(client, Ok(first))
          actor.continue(rest)
        }
      }
  }
}
