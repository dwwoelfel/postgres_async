open Core
open Async
open Int.Replace_polymorphic_compare
module Notification_channel = Types.Notification_channel
module Column_metadata = Column_metadata
module Ssl_mode = Ssl_mode

(* https://www.postgresql.org/docs/current/protocol.html *)

module Pgasync_error = struct
  (* The MLI introduces the [Pgasync_error] type; it's our place to store the generic
     error, and the error code _if_ we know it.

     Now, on the subject of error handling more generally, there are a few axes on which
     one must make a decision here.

     API
     ---
     First and foremost, we need to decide whether or not we should expose a single api,
     where all the result types are [Or_pgasync_error.t], or should we expose a more
     convenient API that uses [Or_error.t], and an expert API that uses
     [Or_pgasync_error.t]? We do the latter, because the vast majority of our users don't
     care for the [postgres_error_code] and do use [Error.t] everywhere else.

     Internal storage of connection-killing errors
     ---------------------------------------------
     But more subtly, once you've agreed to provide [postgres_error_code], you need to be
     very careful about when you provide it. If you return an error from [query] with
     [postgres_error_code = Some _] in it, then the user will quite reasonably assume that
     the query failed with that error. But that might not be true: if the connection
     previously asynchronously failed due to some error (say, the connection closed),
     we're going to return that error to the user.

     This is a problem, because the error that closed the connection might imply that
     a specific thing is wrong with their query, when actually it is not. I don't have
     a great example, but suppose that there existed an error code relating to replication
     that might cause the backend to die.

     If the backend asynchronously dies, we'll close [t] and stash the reason it closed
     inside [t.state]. If someone then tries to use [query t], we'll fetch the reason
     out of [t.state], and return that as an error. But if we did this naively, then it
     would look to the user like their specific query conflicted with replication, and
     they might retry it, when actually that was unrelated.

     The important thing here is: we should only return a [postgres_error_code] that has
     semantic meaning to the user _if_ it relates to the operation they just performed,
     not some operation that happened previously.

     You could imagine two different ways of trying to achieve this:

     1) Only ever stash [Error.t]s inside [state] (or similar). This ensures we'll never
     fetch a [postgres_error_code] out of storage and give it to the user.

     But this is tricky, because now we have a mixture of different error types in the
     library, which is super annoying and messy, and you have to be careful about when you
     use one vs. the other, and you have to keep converting back and forth.

     Furthermore, you need to be careful that a refactor cause an error relating to
     a specific query to be stashed and immediately retrieved, as that might erase the
     error code, or passed through some generic function that erases

     2) Use [Pgasync_error.t] everywhere within the library, but before every operation
     like [query], examine [t.state] to see if the connection is already dead, and make
     sure that when you return the stashed [Pgasync_error.t], you erase the code from it
     (and tag it with a message like "query issued on closed connection; original error
     was foo" too).

     We do #2.

     This is precisely achieved by the first line of [parse_and_start_executing_query].

     We're using the simplifying argument that even if an error gets stashed in [t.state]
     and then returned to the user at the end of [query], that error _wasn't_ there when
     the query was started, so it's reasonable to associate it with the [query], which
     sounds fine. *)


  module Postgres_field = Protocol.Backend.Error_or_notice_field

  type server_error = Protocol.Backend.ErrorResponse.t =
    { error_code : string
    ; all_fields : (Postgres_field.t * string) list
    }

  type t =
    { error : Error.t
    ; server_error : server_error option
    }

  let sexp_of_t t = [%sexp (t.error : Error.t)]
  let of_error e = { error = e; server_error = None }
  let of_exn e = of_error (Error.of_exn e)
  let of_string s = of_error (Error.of_string s)
  let create_s s = of_error (Error.create_s s)

  let of_error_response (error_response : Protocol.Backend.ErrorResponse.t) =
    let error =
      (* We omit some of the particularly noisy and uninteresting fields from the error
         message that will be displayed to users.

         Note that as-per [ErrorResponse.t]'s docstring, [Code] is included in this
         list. *)
      let interesting_fields =
        List.filter error_response.all_fields ~f:(fun (field, value) ->
          match field with
          | File | Line | Routine | Severity_non_localised -> false
          | Severity ->
            (* ERROR is the normal case for an error message, so just omit it *)
            String.( <> ) value "ERROR"
          | _ -> true)
      in
      Error.create_s [%sexp (interesting_fields : (Postgres_field.t * string) list)]
    in
    { error; server_error = Some error_response }
  ;;

  let tag t ~tag = { t with error = Error.tag t.error ~tag }
  let to_error t = t.error

  let postgres_error_code t =
    match t.server_error with
    | None -> None
    | Some { error_code; _ } -> Some error_code
  ;;

  let postgres_field t field =
    match t.server_error with
    | None -> None
    | Some { all_fields; _ } ->
      List.Assoc.find all_fields field ~equal:[%equal: Postgres_field.t]
  ;;

  let raise t = Error.raise t.error
end

module Or_pgasync_error = struct
  type 'a t = ('a, Pgasync_error.t) Result.t [@@deriving sexp_of]

  let to_or_error = Result.map_error ~f:Pgasync_error.to_error

  let ok_exn = function
    | Ok x -> x
    | Error e -> Pgasync_error.raise e
  ;;

  let error_s s = Error (Pgasync_error.create_s s)
  let error_string s = Error (Pgasync_error.of_string s)
  let errorf fmt = ksprintf error_string fmt
  let of_exn e = Error (Pgasync_error.of_exn e)
end

module Expert = struct
  (* Unlike the [Closing]...[Closed_gracefully] sequence, when an error occurs we must
     immediately transition to the [Failed] state, to prevent any other operations being
     attempted while we are releasing resources.

     So that [closed_finished] can wait on all resources to be released in the [Failed]
     case, we have this bool [resources_released].

     The reason we don't model graceful close this way is because [Closing] can transition
     to either of [Failed _] or [Closed_gracefully] states; putting a bool in that
     constructor makes it sound like we never transition away from some hypothetical
     [Closed _] constructor. *)
  type state =
    | Open
    | Closing
    | Failed of
        { error : Pgasync_error.t
        ; resources_released : bool
        }
    | Closed_gracefully
  [@@deriving sexp_of]

  (* There are a couple of invariants we need to be careful of:

     - changes to [t.state] need simultaneous ivar filling and/or reader & writer closing.
     - [t.state = Open _] must imply [t.reader] is not closed

     Further, we need to be careful to catch synchronous writer exceptions and write flush
     messages to postgres.

     We try and make sure these invariants hold by making some of the fields in [t] opaque
     to stuff outside of this small module, so that by reading the short [module T] we can
     be confident the whole module handles this correctly.

     (It's not perfect, e.g. [t.reader] is exposed, but this isn't awful.) *)
  module T : sig
    (* [opaque] makes [writer] and [state_changed] inaccessible outside of [T]. *)
    type 'a opaque

    type t = private
      { writer : Writer.t opaque
      ; reader : Reader.t
      ; mutable state : state
      ; state_changed : (unit, read_write) Bvar.t opaque
      ; sequencer : Query_sequencer.t
      ; runtime_parameters : string String.Table.t
      ; notification_buses :
          (Pid.t -> string -> unit, read_write) Bus.t Notification_channel.Table.t
      ; backend_key : Types.backend_key Set_once.t
      }
    [@@deriving sexp_of]

    val create_internal : Reader.t -> Writer.t -> t
    val failed : t -> Pgasync_error.t -> unit

    type to_flush_or_not =
      | Not_required
      | Write_afterwards

    (** [flush_message] is a bit of a weird argument for this function/weird feature
        to give this part of the code, but it reminds us to always consider the need
        to flush. *)
    val catch_write_errors
      :  t
      -> f:(Writer.t -> unit)
      -> flush_message:to_flush_or_not
      -> unit

    val bytes_pending_in_writer_buffer : t -> int
    val wait_for_writer_buffer_to_be_empty : t -> unit Deferred.t
    val status : t -> state
    val close_finished : t -> unit Or_pgasync_error.t Deferred.t
    val close : t -> unit Or_pgasync_error.t Deferred.t
  end = struct
    type 'a opaque = 'a

    type t =
      { writer : (Writer.t[@sexp.opaque])
      ; reader : (Reader.t[@sexp.opaque])
      ; mutable state : state
      ; state_changed : (unit, read_write) Bvar.t
      ; sequencer : Query_sequencer.t
      ; runtime_parameters : string String.Table.t
      ; notification_buses :
          (Pid.t -> string -> unit, read_write) Bus.t Notification_channel.Table.t
      ; backend_key : Types.backend_key Set_once.t
      }
    [@@deriving sexp_of]

    let set_state t state =
      t.state <- state;
      Bvar.broadcast t.state_changed ()
    ;;

    let cleanup_resources t =
      let%bind () = Writer.close t.writer ~force_close:Deferred.unit in
      let%bind () = Reader.close t.reader in
      Hashtbl.clear t.notification_buses;
      Hashtbl.clear t.runtime_parameters;
      return ()
    ;;

    let failed t error =
      match t.state with
      | Failed _ | Closed_gracefully -> ()
      | Open | Closing ->
        set_state t (Failed { error; resources_released = false });
        don't_wait_for
          (let%bind () = cleanup_resources t in
           set_state t (Failed { error; resources_released = true });
           return ())
    ;;

    let create_internal reader writer =
      { reader
      ; writer
      ; state = Open
      ; state_changed = Bvar.create ()
      ; sequencer = Query_sequencer.create ()
      ; runtime_parameters = String.Table.create ()
      ; notification_buses = Notification_channel.Table.create ~size:1 ()
      ; backend_key = Set_once.create ()
      }
    ;;

    type to_flush_or_not =
      | Not_required
      | Write_afterwards

    let catch_write_errors t ~f ~flush_message : unit =
      match f t.writer with
      | exception exn -> failed t (Pgasync_error.of_exn exn)
      | () ->
        (match flush_message with
         | Not_required -> ()
         | Write_afterwards ->
           (match Protocol.Frontend.Writer.flush t.writer with
            | exception exn -> failed t (Pgasync_error.of_exn exn)
            | () -> ()))
    ;;

    let bytes_pending_in_writer_buffer t = Writer.bytes_to_write t.writer
    let wait_for_writer_buffer_to_be_empty t = Writer.flushed t.writer

    let do_close_gracefully_if_possible t =
      match t.state with
      | Failed _ | Closed_gracefully | Closing -> return ()
      | Open ->
        set_state t Closing;
        let closed_gracefully_deferred =
          Query_sequencer.enqueue t.sequencer (fun () ->
            catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
              Protocol.Frontend.Writer.terminate writer);
            (* we'll get an exception if the reader is already closed. *)
            match%bind
              Monitor.try_with ~run:`Now ~rest:`Log (fun () ->
                Reader.read_char t.reader)
            with
            | Ok `Eof -> return (Ok ())
            | Ok (`Ok c) ->
              return (Or_pgasync_error.errorf "EOF expected, but got '%c'" c)
            | Error exn -> return (Or_pgasync_error.of_exn exn))
        in
        (match%bind Clock.with_timeout (sec 1.) closed_gracefully_deferred with
         | `Timeout ->
           failed t (Pgasync_error.of_string "EOF expected, but instead stuck");
           return ()
         | `Result (Error err) ->
           failed t err;
           return ()
         | `Result (Ok ()) ->
           let%bind () = cleanup_resources t in
           (match t.state with
            | Open | Closed_gracefully -> assert false
            | Failed _ ->
              (* e.g., if the Writer had an asynchronous exn while the reader was being
                 closed, we might have called [failed t] and filled this ivar already. *)
              return ()
            | Closing ->
              set_state t Closed_gracefully;
              return ()))
    ;;

    let status t = t.state

    let rec close_finished t =
      match t.state with
      | Failed { error; resources_released = true } -> return (Error error)
      | Closed_gracefully -> return (Ok ())
      | Closing | Open | Failed { resources_released = false; _ } ->
        let%bind () = Bvar.wait t.state_changed in
        close_finished t
    ;;

    let close t =
      don't_wait_for (do_close_gracefully_if_possible t);
      close_finished t
    ;;
  end

  include T

  let notification_bus t channel =
    Hashtbl.find_or_add t.notification_buses channel ~default:(fun () ->
      Bus.create
        [%here]
        Arity2
        ~on_subscription_after_first_write:Allow
        ~on_callback_raise:Error.raise)
  ;;

  (* [Message_reading] hides the helper functions of [read_messages] from the below. *)
  module Message_reading : sig
    type 'a handle_message_result =
      | Stop of 'a
      | Continue
      | Protocol_error of Pgasync_error.t

    (** [read_messages] and will handle and dispatch the three asynchronous message types
        for you; you should never see them.

        [handle_message] is given a message type constructor, and an iobuf windowed on the
        payload of the message (that is, the message-type-specific bytes; the window does
        not include the type or message length header, they have already been consumed).

        [handle_message] must consume (as in [Iobuf.Consume]) all of the bytes of the
        message. *)
    type 'a handle_message =
      Protocol.Backend.constructor
      -> (read, Iobuf.seek) Iobuf.t
      -> 'a handle_message_result

    type 'a read_messages_result =
      | Connection_closed of Pgasync_error.t
      | Done of 'a

    (** NoticeResponse, and ParameterStatus and NotificationResponse are 'asynchronous
        messages' and are not associated with a specific request-response conversation.
        They can happen at any time.

        [read_messages] handles these for you, and does not show them to your
        [handle_message] callback.  *)
    val read_messages
      :  ?pushback:(unit -> unit Deferred.t)
      -> t
      -> handle_message:'a handle_message
      -> 'a read_messages_result Deferred.t

    (** If a message arrives while no request-response conversation (query or otherwise)
        is going on, use [consume_one_asynchronous_message] to eat it.

        If the message is one of those asynchronous messages, it will be handled. If it is
        some other message type, that is a protocol error and the connection will be
        closed. If the reader is actually at EOF, the connection will be closed with an
        error. *)
    val consume_one_asynchronous_message : t -> unit read_messages_result Deferred.t
  end = struct
    type 'a handle_message_result =
      | Stop of 'a
      | Continue
      | Protocol_error of Pgasync_error.t

    let max_message_length =
      let default = 50 * 1024 * 1024 in
      lazy
        (let override =
           (* for emergencies, in case 50M is a terrible default (seems very unlikely) *)
           let open Option.Let_syntax in
           let%bind v = Unix.getenv "POSTGRES_ASYNC_OVERRIDE_MAX_MESSAGE_LENGTH" in
           let%bind v = Option.try_with (fun () -> Int.of_string v) in
           let%bind v = Option.some_if (v > 0) v in
           Some v
         in
         Option.value override ~default)
    ;;

    type 'a handle_message =
      Protocol.Backend.constructor
      -> (read, Iobuf.seek) Iobuf.t
      -> 'a handle_message_result

    (* [Reader.read_one_iobuf_at_a_time] hands us 'chunks' to [handle_chunk]. A chunk is
       an iobuf, where the window of the iobuf is set to the data that has been pulled
       from the OS into the [Reader.t] but not yet consumed by the application. Said
       window 'chunk' contains messages, potentially a partial message at the end in case
       e.g. the bytes of a message is split across two calls to the [read] syscall.

       Suppose the server has send us three 5-byte messages, "AAAAA", "BBBBB" and "CCCCC".
       Each message has a 5-byte header (containing its type and length), represented by
       'h'. Suppose further that the OS handed us 23 bytes when [Reader.t] called [read].

       {v
          0 bytes   10 bytes  20 bytes
          |         |         |
          hhhhhAAAAAhhhhhBBBBBhhh
         /--------window---------\
       v}

       We want to give each message to [handle_message], one at a time. So, first we must
       move the window on the iobuf so that it contains precisely the first message's
       payload, i.e., the bytes 'AAAAA', i.e., this iobuf but with the window set to
       [5,10). [Protocol.Backend.focus_on_message] does this by consuming the header
       'hhhhh' to learn the type and length (thereby moving the window lo-bound up) and
       then resizing it (moving the hi-bound down) like so:

       {v
          hhhhhAAAAAhhhhhBBBBBhhh
              /-wdw-\
       v}

       Now we can call [handle_message] with this iobuf.

       The contract we have with [handle_message] is that it will use calls to functions
       in [Iobuf.Consume] to consume the bytes inside the window we set, that is, consume
       the entire message. As it consumes bytes of the message, the window lo-bound is
       moved up, so when it's done consuming the window is [10,10)

       {v
          hhhhhAAAAAhhhhhBBBBBhhh
                   /\
       v}

       and then [bounded_flip_hi] sets the window to [10,23) (since we remembered '23' in
       [chunk_hi_bound]).

       {v
          hhhhhAAAAAhhhhhBBBBBhhh
                   /-----window--\
       v}

       then, we recurse (focus on [15,20), call [handle_message], etc.), and recurse
       again.

       At this point, reading the 'message length' field tells us that we only have part
       of 'C' in our buffer (three out of 5+5 bytes). So, we return from [handle_chunk].
       The contract we have with [Reader.t] is that we will leave in the iobuf the data
       that we did not consume. It looks at the iobuf window to understand what's left,
       keeps only those three bytes of 'C' in its internal buffer, and uses [read] to
       refill the buffer before calling us again; hopefully at that point we'll have the
       whole of message 'C'.

       For this to work it is important that [handle_message] actually consumed the whole
       message, and did not move the window hi-bound. We _could_ save those bounds and
       forcibly restore them before doing the flip, however we prefer to instead just
       check that [handle_message] did this because the functions that parse messages are
       written to 'consume' them anyway, and checking that they actually did so is a good
       validation that we correctly understand and are thinking about all fields in the
       postgres protocol; not consuming all the bytes of the message indicates a potential
       parsing bug. That's what [check_window_after_handle_message] does.

       Note the check against [max_message_length]. Without it, if postgres told us that
       it was sending us an extremely long message, we'd return from [handle_chunk]
       constantly asking for refills, always thinking we needed more data and consuming
       all the RAM. Instead, we will just bail out rather than asking for refills if
       a message gets too long. The limit is arbitrary, but ought to be enough for anybody
       (with an environment variable escape hatch if we turn out to be wrong). *)

    let check_window_after_handle_message message_type iobuf ~message_hi_bound =
      match
        [%compare.equal: Iobuf.Hi_bound.t] (Iobuf.Hi_bound.window iobuf) message_hi_bound
      with
      | false ->
        Or_pgasync_error.error_s
          [%message
            "handle_message moved the hi-bound!"
              (message_type : Protocol.Backend.constructor)]
      | true ->
        (match Iobuf.is_empty iobuf with
         | false ->
           Or_pgasync_error.error_s
             [%message
               "handle_message did not consume entire iobuf"
                 (message_type : Protocol.Backend.constructor)
                 ~bytes_remaining:(Iobuf.length iobuf : int)]
         | true -> Ok ())
    ;;

    let handle_chunk ~handle_message ~pushback =
      let stop_error sexp =
        return (`Stop (`Protocol_error (Pgasync_error.create_s sexp)))
      in
      let rec loop iobuf =
        let chunk_hi_bound = Iobuf.Hi_bound.window iobuf in
        match Protocol.Backend.focus_on_message iobuf with
        | Error Iobuf_too_short_for_header ->
          let%bind () = pushback () in
          return `Continue
        | Error (Iobuf_too_short_for_message { message_length }) ->
          (match message_length > force max_message_length with
           | true -> stop_error [%message "Message too long" (message_length : int)]
           | false ->
             let%bind () = pushback () in
             return `Continue)
        | Error (Nonsense_message_length v) ->
          stop_error [%message "Nonsense message length in header" ~_:(v : int)]
        | Error (Unknown_message_type other) ->
          stop_error [%message "Unrecognised message type character" (other : char)]
        | Ok message_type ->
          let message_hi_bound = Iobuf.Hi_bound.window iobuf in
          let res =
            let iobuf = Iobuf.read_only iobuf in
            handle_message message_type iobuf
          in
          let res =
            match res with
            | Protocol_error _ as res -> res
            | (Stop _ | Continue) as res ->
              (match
                 check_window_after_handle_message message_type iobuf ~message_hi_bound
               with
               | Error err -> Protocol_error err
               | Ok () -> res)
          in
          Iobuf.bounded_flip_hi iobuf chunk_hi_bound;
          (match res with
           | Protocol_error err -> return (`Stop (`Protocol_error err))
           | Continue -> loop iobuf
           | Stop s -> return (`Stop (`Done s)))
      in
      Staged.stage loop
    ;;

    let no_pushback () = return ()

    type 'a read_messages_result =
      | Connection_closed of Pgasync_error.t
      | Done of 'a

    let can't_read_because_closed =
      lazy
        (return
           (Connection_closed (Pgasync_error.of_string "can't read: closed or closing")))
    ;;

    let run_reader ?(pushback = no_pushback) t ~handle_message =
      let handle_chunk = Staged.unstage (handle_chunk ~handle_message ~pushback) in
      match t.state with
      | Failed { error; _ } -> return (Connection_closed error)
      | Closed_gracefully | Closing -> force can't_read_because_closed
      | Open ->
        (* [t.state] = [Open _] implies [t.reader] is not closed, and so this function will
           not raise. Note further that if the reader is closed _while_ we are reading, it
           does not raise. *)
        let%bind res = Reader.read_one_iobuf_at_a_time t.reader ~handle_chunk in
        (* In case of some failure (writer failure, including asynchronous) the
           reader will be closed and reads will return Eof. So, after the read
           result is determined, we check [t.state], so that we can give a better
           error message than "unexpected EOF". *)
        (match t.state with
         | Failed { error; _ } -> return (Connection_closed error)
         | Closing | Closed_gracefully -> force can't_read_because_closed
         | Open ->
           let res =
             match res with
             | `Stopped s -> s
             | `Eof_with_unconsumed_data data ->
               `Protocol_error
                 (Pgasync_error.create_s
                    [%message
                      "Unexpected EOF" ~unconsumed_bytes:(String.length data : int)])
             | `Eof ->
               `Protocol_error
                 (Pgasync_error.of_string "Unexpected EOF (no unconsumed messages)")
           in
           (match res with
            | `Protocol_error err ->
              failed t err;
              return (Connection_closed err)
            | `Done res -> return (Done res)))
    ;;

    let handle_notice_response iobuf =
      match Protocol.Backend.NoticeResponse.consume iobuf with
      | Error err -> Error (Pgasync_error.of_error err)
      | Ok { error_code = _; all_fields } ->
        Log.Global.sexp
          ~level:`Info
          [%message
            "Postgres NoticeResponse"
              ~_:(all_fields : (Protocol.Backend.Error_or_notice_field.t * string) list)];
        Ok ()
    ;;

    let handle_parameter_status t iobuf =
      match Protocol.Backend.ParameterStatus.consume iobuf with
      | Error err -> Error (Pgasync_error.of_error err)
      | Ok { key; data } ->
        Hashtbl.set t.runtime_parameters ~key ~data;
        Ok ()
    ;;

    let handle_notification_response t iobuf =
      match Protocol.Backend.NotificationResponse.consume iobuf with
      | Error err -> Error (Pgasync_error.of_error err)
      | Ok { pid; channel; payload } ->
        let bus = notification_bus t channel in
        (match Bus.num_subscribers bus with
         | 0 ->
           Log.Global.sexp
             ~level:`Error
             [%message
               "Postgres NotificationResponse on channel that no callbacks are listening \
                to"
                 (channel : Notification_channel.t)]
         | _ -> Bus.write2 bus pid payload);
        Ok ()
    ;;

    let read_messages ?pushback t ~handle_message =
      let continue_if_ok = function
        | Error err -> Protocol_error err
        | Ok () -> Continue
      in
      let handle_message message_type iobuf =
        match (message_type : Protocol.Backend.constructor) with
        | NoticeResponse -> continue_if_ok (handle_notice_response iobuf)
        | ParameterStatus -> continue_if_ok (handle_parameter_status t iobuf)
        | NotificationResponse -> continue_if_ok (handle_notification_response t iobuf)
        | _ -> handle_message message_type iobuf
      in
      run_reader ?pushback t ~handle_message
    ;;

    let consume_one_asynchronous_message t =
      let stop_if_ok = function
        | Error err -> Protocol_error err
        | Ok () -> Stop ()
      in
      let handle_message message_type iobuf =
        match (message_type : Protocol.Backend.constructor) with
        | NoticeResponse -> stop_if_ok (handle_notice_response iobuf)
        | ParameterStatus -> stop_if_ok (handle_parameter_status t iobuf)
        | NotificationResponse -> stop_if_ok (handle_notification_response t iobuf)
        | ErrorResponse ->
          (* ErrorResponse is a weird one, because it's very much a message that's part of
             the request-response part of the protocol, but secretly you will actually get
             one if e.g. your backend is terminated by [pg_terminate_backend]. The fact
             that this asynchronous error-response possibility isn't mentioned in the
             "protocol-flow" docs kinda doesn't matter as the connection is being
             destroyed.

             Ultimately handling it specially here only changes the contents of the
             [Protocol_error _] we return (i.e., behaviour is unch vs. the catch-all
             case). Think of it as giving people better error messages, not a semantic
             thing. *)
          let tag =
            "ErrorResponse received asynchronously, assuming connection is dead"
          in
          let error =
            match Protocol.Backend.ErrorResponse.consume iobuf with
            | Error err -> Pgasync_error.of_error err
            | Ok err -> Pgasync_error.of_error_response err |> Pgasync_error.tag ~tag
          in
          Protocol_error error
        | other ->
          Protocol_error
            (Pgasync_error.create_s
               [%message
                 "Unsolicited message from server outside of query conversation"
                   (other : Protocol.Backend.constructor)])
      in
      run_reader t ~handle_message
    ;;
  end

  include Message_reading

  let protocol_error_of_error error = Protocol_error (Pgasync_error.of_error error)
  let protocol_error_s sexp = Protocol_error (Pgasync_error.create_s sexp)

  let unexpected_msg_type msg_type state =
    protocol_error_s
      [%message
        "Unexpected message type"
          (msg_type : Protocol.Backend.constructor)
          (state : Sexp.t)]
  ;;

  let login t ~user ~password ~gss_krb_token ~database =
    catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
      Protocol.Frontend.Writer.startup_message writer { user; database });
    read_messages t ~handle_message:(fun msg_type iobuf ->
      match msg_type with
      | AuthenticationRequest ->
        let module Q = Protocol.Backend.AuthenticationRequest in
        (match Q.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok Ok -> Continue
         | Ok (MD5Password { salt }) ->
           (match password with
            | Some password ->
              let d s = Md5.to_hex (Md5.digest_string s) in
              let md5_hex = "md5" ^ d (d (password ^ user) ^ salt) in
              catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
                Protocol.Frontend.Writer.password_message
                  writer
                  (Cleartext_or_md5_hex md5_hex));
              Continue
            | None ->
              let s = "Server requested (md5) password, but no password was provided" in
              Stop (Or_pgasync_error.error_string s))
         | Ok GSS ->
           (match gss_krb_token with
            | Some token ->
              catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
                Protocol.Frontend.Writer.password_message writer (Gss_binary_blob token));
              Continue
            | None ->
              let s = "Server requested GSS auth, but no gss_krb_token was provided" in
              Stop (Or_pgasync_error.error_string s))
         | Ok other ->
           let s =
             sprintf !"Server wants unimplemented auth subtype: %{sexp:Q.t}" other
           in
           Stop (Or_pgasync_error.error_string s))
      | BackendKeyData ->
        (match Protocol.Backend.BackendKeyData.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok data ->
           (match Set_once.set t.backend_key [%here] data with
            | Ok () -> Continue
            | Error _ -> protocol_error_s [%sexp "duplicate BackendKeyData messages"]))
      | ReadyForQuery ->
        let module Q = Protocol.Backend.ReadyForQuery in
        (match Q.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok Idle -> Stop (Ok ())
         | Ok st ->
           protocol_error_s [%message "Unexpected initial transaction status" (st : Q.t)])
      | ErrorResponse ->
        (match Protocol.Backend.ErrorResponse.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok err -> Stop (Error (Pgasync_error.of_error_response err)))
      | msg_type -> unexpected_msg_type msg_type [%sexp "logging in"])
  ;;

  (* So there are a few different ways one could imagine handling asynchronous messages,
     and it basically breaks down to whether or not you have a single background job
     pulling messages out of the reader, filtering away asynchronous messages, and putting
     the remainder somewhere that request-response functions can pull them out of, or you
     have some way of synchronising access to the reader and noticing if it lights up
     while no request-response function is running.

     We've gone for the latter, basically because efficiently handing messages from the
     background to request-response functions is painful, and it puts a lot of complicated
     state into [t] (the background job can't be separate, because it needs to know
     whether or not [t.sequencer] is in use in order to classify an [ErrorResponse] as
     part of request-response or as asynchronous).

     The tradeoff is that we need a custom [Query_sequencer] module for the [when_idle]
     function (though at least that can be a separate, isolated module), and we need to
     use the fairly low level [interruptible_ready_to] on the [Reader]'s fd (which is
     skethcy). All in, I think this turns out to be simpler, and it also isolates the
     features that add async message support from the rest of the library. *)
  let handle_asynchronous_messages t =
    Query_sequencer.when_idle t.sequencer (fun () ->
      let module Q = Query_sequencer in
      match t.state with
      | Failed _ | Closing | Closed_gracefully -> return Q.Finished
      | Open ->
        let%bind res =
          match Reader.bytes_available t.reader > 0 with
          | true -> return `Ready
          | false ->
            Fd.interruptible_ready_to
              (Reader.fd t.reader)
              `Read
              ~interrupt:(Query_sequencer.other_jobs_are_waiting t.sequencer)
        in
        (match t.state with
         | Closed_gracefully | Closing | Failed _ -> return Q.Finished
         | Open ->
           (match res with
            | `Interrupted -> return Q.Call_me_when_idle_again
            | (`Bad_fd | `Closed) as res ->
              (* [t.state = Open _] implies the reader is open. *)
              raise_s
                [%message "handle_asynchronous_messages" (res : [ `Bad_fd | `Closed ])]
            | `Ready ->
              (match%bind consume_one_asynchronous_message t with
               | Connection_closed _ -> return Q.Finished
               | Done () -> return Q.Call_me_when_idle_again))))
  ;;

  let default_user =
    Memo.unit (fun () ->
      Monitor.try_with_or_error ~rest:`Log (fun () -> Unix.getlogin ()))
  ;;

  type packed_where_to_connect =
    | Where_to_connect : 'a Tcp.Where_to_connect.t -> packed_where_to_connect

  let default_where_to_connect =
    lazy (Where_to_connect (Tcp.Where_to_connect.of_file "/run/postgresql/.s.PGSQL.5432"))
  ;;

  let maybe_ssl_wrap ~interrupt ~ssl_mode ~tcp_reader ~tcp_writer =
    let negotiate_ssl ~required =
      match Protocol.Frontend.Writer.ssl_request tcp_writer () with
      | exception exn -> return (Or_error.of_exn exn)
      | () ->
        (match%bind
           choose
             [ choice interrupt (fun () -> `Interrupt)
             ; choice (Reader.read_char tcp_reader) (function
                 | `Eof -> `Eof
                 | `Ok char -> `Ok char)
             ]
         with
         | `Interrupt -> return (error_s [%message "ssl negotiation interrupted"])
         | `Eof ->
           return (error_s [%message "Reader closed before ssl negotiation response"])
         | `Ok 'S' ->
           (* [Prefer] and [Require] do not demand certificate verification, which is
              why you see us assign [Verify_none] and a [verify_callback] that
              unconditionally returns [Ok ()]. We'd need to revisit that if we added
              [Ssl_mode.t] constructors akin to libpq's [Verify_ca] or
              [Verify_full]. *)
           Monitor.try_with_or_error ~rest:`Log (fun () ->
             let%bind t, (_ : [ `Connection_closed of unit Deferred.t ]) =
               Async_ssl.Tls.Expert.wrap_client_connection_and_stay_open
                 (Async_ssl.Config.Client.create
                    ~verify_modes:[ Verify_none ]
                    ~ca_file:None
                    ~ca_path:None
                    ~remote_hostname:None
                    ~verify_callback:(fun (_ : Async_ssl.Ssl.Connection.t) ->
                      return (Ok ()))
                    ())
                 tcp_reader
                 tcp_writer
                 ~f:(fun (_ : Async_ssl.Ssl.Connection.t) ssl_reader ssl_writer ->
                   let t = create_internal ssl_reader ssl_writer in
                   let close_finished_deferred =
                     let%bind (_ : unit Or_pgasync_error.t) = close_finished t in
                     return ()
                   in
                   return (t, `Do_not_close_until close_finished_deferred))
             in
             return t)
         | `Ok 'N' ->
           (match required with
            | true ->
              return
                (error_s
                   [%message
                     "Server indicated it cannot use SSL connections, but ssl_mode is set \
                      to Require"])
            | false ->
              (* 'N' means the server is unwilling to use SSL connections, but is happy to
                 proceed without encryption (and sending a [StartupMessage] on the same
                 connection is the correct way to do so). *)
              return (Ok (create_internal tcp_reader tcp_writer)))
         | `Ok response_char ->
           (* 'E' (or potentially another character?) can indicate that the server
              doesn't understand the request, and we must re-start the connection from
              scratch.

              This should only happen for ancient versions of postgres, which are not
              supported by this library. *)
           return
             (error_s
                [%message
                  "Postgres Server indicated it does not understand the SSLRequest \
                   message. This may mean that the server is running a very outdated \
                   version of postgres, or some other problem may be occuring. You can \
                   try to run with ssl_mode = Disable to skip the SSLRequest and use \
                   plain TCP."
                    (response_char : Char.t)]))
    in
    match (ssl_mode : Ssl_mode.t) with
    | Disable ->
      let t = create_internal tcp_reader tcp_writer in
      return (Ok t)
    | Prefer -> negotiate_ssl ~required:false
    | Require -> negotiate_ssl ~required:true
  ;;

  let connect_tcp_and_maybe_start_ssl ~interrupt ~ssl_mode server =
    match%bind
      Monitor.try_with_or_error ~rest:`Log (fun () -> Tcp.connect ~interrupt server)
    with
    | Error _ as result -> return result
    | Ok (_sock, tcp_reader, tcp_writer) ->
      (match%bind maybe_ssl_wrap ~interrupt ~ssl_mode ~tcp_reader ~tcp_writer with
       | Error _ as result ->
         let%bind () = Writer.close tcp_writer in
         let%bind () = Reader.close tcp_reader in
         return result
       | Ok t ->
         let writer_failed =
           Monitor.detach_and_get_next_error (Writer.monitor tcp_writer)
         in
         return (Ok (t, writer_failed)))
  ;;

  let connect
        ?(interrupt = Deferred.never ())
        ?(ssl_mode = Ssl_mode.Disable)
        ?server
        ?user
        ?password
        ?gss_krb_token
        ~database
        ()
    =
    let (Where_to_connect server) =
      match server with
      | Some x -> Where_to_connect x
      | None -> force default_where_to_connect
    in
    let%bind (user : string Or_error.t) =
      match user with
      | Some u -> return (Ok u)
      | None -> default_user ()
    in
    match user with
    | Error err -> return (Error (Pgasync_error.of_error err))
    | Ok user ->
      (match%bind connect_tcp_and_maybe_start_ssl ~interrupt ~ssl_mode server with
       | Error error -> return (Error (Pgasync_error.of_error error))
       | Ok (t, writer_failed) ->
         upon writer_failed (fun exn ->
           failed
             t
             (Pgasync_error.create_s
                [%message "Writer failed asynchronously" (exn : Exn.t)]));
         let login_failed err =
           failed t err;
           return (Error err)
         in
         (match%bind
            choose
              [ choice interrupt (fun () -> `Interrupt)
              ; choice (login t ~user ~password ~gss_krb_token ~database) (fun l ->
                  `Result l)
              ]
          with
          | `Interrupt -> login_failed (Pgasync_error.of_string "login interrupted")
          | `Result (Connection_closed err) -> return (Error err)
          | `Result (Done (Error err)) -> login_failed err
          | `Result (Done (Ok ())) ->
            handle_asynchronous_messages t;
            return (Ok t)))
  ;;

  let with_connection
        ?interrupt
        ?ssl_mode
        ?server
        ?user
        ?password
        ?gss_krb_token
        ~database
        ~on_handler_exception:`Raise
        func
    =
    match%bind
      connect ?interrupt ?ssl_mode ?server ?user ?password ?gss_krb_token ~database ()
    with
    | Error _ as e -> return e
    | Ok t ->
      (match%bind Monitor.try_with ~run:`Now ~rest:`Raise (fun () -> func t) with
       | Ok _ as ok_res ->
         let%bind (_ : unit Or_pgasync_error.t) = close t in
         return ok_res
       | Error exn ->
         don't_wait_for
           (let%bind (_ : unit Or_pgasync_error.t) = close t in
            return ());
         raise exn)
  ;;

  (* We use the extended query protocol rather than the simple query protocol because it
     provides support for [parameters] (via the 'bind' message), and because it guarantees
     that only a SQL statement is executed per query, which simplifies the state machine
     we need to use to handle the responses significantly.

     We don't currently take advantage of named statements or portals, we just use the
     'unnamed' ones. We don't take advantage of the ability to bind a statement twice or
     partially execute a portal; we just send the full parse-bind-describe-execute
     sequence unconditionally in one go.

     Ultimately, one needs to read the "message flow/extended query" section of the
     documentation:

     https://www.postgresql.org/docs/10/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY

     What follows is a brief summary, and then a description of how the different
     functions fit in.

     When any error occurs, the server will report the error and tehen discard messages
     until a 'sync' message. This means that we can safely send
     parse-bind-describe-execute in one go and then read all the responses, because if one
     step fails the remainder will be ignored. So, we do this because it improves latency.

     [parse_and_start_executing_query] instructs the server to parse the query, bind the
     parameters, describe the type of the rows that will be produced. It then reads
     response messages, walking through a state machine. The first three states are easy,
     because we expect either the relevant response messages (ParseComplete, BindComplete,
     RowDescription|NoData), or an ErrorResponse.

     After that, things are trickier. We don't know what string was in the query and
     whether or not the query emits no data (e.g., a DELETE), or if server is going to
     send us rows, or if it's going to try and COPY IN/OUT, etc.

     [parse_and_start_executing_query] detects which case we're in and returns a value of
     type [setup_loop_result] indicating this. It's a little weird because we don't want
     to consume any of the actual data (if applicable) in that funciton, just detect the
     mode.

     If the response to the [Describe] message was a [RowDescription], we know that the
     response to the [Execute] will be some [DataRow]s, so we don't look at any messages
     after that (i.e., in that case we don't look at the response to [Execute] in this
     function).

     However if the response to [Describe] was [NoData], then we _have_ to look at the
     first message in response to the [Execute] message to know which case we're in.
     _Fortunately_, the first message in all the other cases does not actually contain any
     data, so we can do what we want (detect mode and return).

     Here they are:

     - [About_to_deliver_rows] e.g., a SELECT. We know we're in this case iff the response
       to our [Describe] message was a [RowDescription], and we don't look at the response
       to the [Execute] message; the caller is responsible for consuming the [DataRow]s.
     - [About_to_copy_out] i.e., COPY ... TO STDOUT. We're here iff we get
       a [CopyOutResponse] in response to our [Execute].
     - [Ready_to_copy_in] i.e., COPY ... FROM STDIN. We're here iff we get
       a [CopyInResponse]. We return, and the caller is responsible for sending a load of
       [CopyData] messages etc.
     - [EmptyQuery] i.e., the query was the empty string. We're here if we get
       a [EmptyQueryResponse], at which point we're done (and can sync); we do not expect
       a [CommandComplete].
     - [Command_complete_without_output], e.g. a DELETE. We're here if we just get
       [CommandComplete] straight away.

     Note that it's also possible for the [About_to_deliver_rows] case to complete without
     output. The difference is that one corresponds to receiving [RowDescription],
     [CommandComplete] and the other [NoData], [CommandComplete]. *)
  type setup_loop_state =
    | Parsing
    | Binding
    | Describing
    | Executing
  [@@deriving sexp_of]

  type setup_loop_result =
    | About_to_deliver_rows of Protocol.Backend.RowDescription.t
    | About_to_copy_out
    | Ready_to_copy_in of Protocol.Backend.CopyInResponse.t
    | Empty_query
    | Command_complete_without_output of Protocol.Backend.CommandComplete.t
    | Remote_reported_error of Pgasync_error.t

  let parse_and_start_executing_query t query_string ~parameters =
    match t.state with
    | Failed { error; _ } ->
      (* See comment at top of file regarding erasing error codes from this error. *)
      return
        (Connection_closed
           (Pgasync_error.create_s
              [%message
                "query issued against previously-failed connection"
                  ~original_error:(error : Pgasync_error.t)]))
    | Closing | Closed_gracefully ->
      return
        (Connection_closed
           (Pgasync_error.of_string "query issued against connection closed by user"))
    | Open ->
      catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
        Protocol.Frontend.Writer.parse
          writer
          { destination = Types.Statement_name.unnamed; query = query_string };
        Protocol.Frontend.Writer.bind
          writer
          { destination = Types.Portal_name.unnamed
          ; statement = Types.Statement_name.unnamed
          ; parameters
          };
        Protocol.Frontend.Writer.describe writer (Portal Types.Portal_name.unnamed);
        Protocol.Frontend.Writer.execute
          writer
          { portal = Types.Portal_name.unnamed; limit = Unlimited });
      let state = ref Parsing in
      let unexpected_msg_type msg_type =
        unexpected_msg_type msg_type [%sexp (state : setup_loop_state ref)]
      in
      read_messages t ~handle_message:(fun msg_type iobuf ->
        match !state, msg_type with
        | state, ErrorResponse ->
          (match Protocol.Backend.ErrorResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok err ->
             let tag =
               sprintf !"Postgres Server Error (state=%{sexp:setup_loop_state})" state
             in
             let err = Pgasync_error.of_error_response err |> Pgasync_error.tag ~tag in
             Stop (Remote_reported_error err))
        | Parsing, ParseComplete ->
          let () = Protocol.Backend.ParseComplete.consume iobuf in
          state := Binding;
          Continue
        | Parsing, msg_type -> unexpected_msg_type msg_type
        | Binding, BindComplete ->
          let () = Protocol.Backend.BindComplete.consume iobuf in
          state := Describing;
          Continue
        | Binding, msg_type -> unexpected_msg_type msg_type
        | Describing, RowDescription ->
          (match Protocol.Backend.RowDescription.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok description -> Stop (About_to_deliver_rows description))
        | Describing, NoData ->
          let () = Protocol.Backend.NoData.consume iobuf in
          state := Executing;
          Continue
        | Describing, msg_type -> unexpected_msg_type msg_type
        | Executing, EmptyQueryResponse ->
          let () = Protocol.Backend.EmptyQueryResponse.consume iobuf in
          Stop Empty_query
        | Executing, CommandComplete ->
          (match Protocol.Backend.CommandComplete.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok (tag) ->
              Stop (Command_complete_without_output tag))
        | Executing, CopyInResponse ->
          (match Protocol.Backend.CopyInResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok details -> Stop (Ready_to_copy_in details))
        | Executing, CopyOutResponse ->
          (match Protocol.Backend.CopyOutResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok _ -> Stop About_to_copy_out)
        | Executing, CopyBothResponse ->
          (* CopyBothResponse is only used for streaming replication, which we do not
             initiate. *)
          unexpected_msg_type msg_type
        | Executing, msg_type -> unexpected_msg_type msg_type)
  ;;

  (* really the return type of [f] should be [Protocol_error _ | Continue], but it's
     convenient to re-use [handle_message_result] and use [Nothing.t] to 'delete' the
     third constructor... *)
  let read_datarows t ~pushback ~f =
    read_messages t ?pushback ~handle_message:(fun msg_type iobuf ->
      match msg_type with
      | DataRow ->
        (match f ~datarow_iobuf:iobuf with
         | (Protocol_error _ | Continue) as x -> x
         | Stop (_ : Nothing.t) -> .)
      | ErrorResponse ->
        (match Protocol.Backend.ErrorResponse.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok err ->
           let err =
             Pgasync_error.of_error_response err
             |> Pgasync_error.tag
                  ~tag:"Error during query execution (despite parsing ok)"
           in
           Stop (Error err))
      | CommandComplete ->
        (match Protocol.Backend.CommandComplete.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok res -> Stop (Ok res))
      | msg_type -> unexpected_msg_type msg_type [%sexp "reading DataRows"])
  ;;

  let drain_datarows t =
    let count = ref 0 in
    let f ~datarow_iobuf =
      incr count;
      Protocol.Backend.DataRow.skip datarow_iobuf;
      Continue
    in
    match%bind read_datarows t ~pushback:None ~f with
    | Connection_closed _ as e -> return e
    | Done (Ok tag) -> return (Done (!count, (Ok tag)))
    | Done (Error e) -> return (Done (!count, Error(e)))
  ;;

  let drain_copy_out t =
    let seen_copy_done = ref false in
    read_messages t ~handle_message:(fun msg_type iobuf ->
      match msg_type with
      | ErrorResponse ->
        (* [ErrorResponse] terminates copy-out mode; no separate [CopyDone] is required. *)
        (match Protocol.Backend.ErrorResponse.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok e -> Stop (Error e))
      | CopyData ->
        (match !seen_copy_done with
         | true -> protocol_error_s [%sexp "CopyData message after CopyDone?"]
         | false ->
           Protocol.Backend.CopyData.skip iobuf;
           Continue)
      | CopyDone ->
        Protocol.Backend.CopyDone.consume iobuf;
        seen_copy_done := true;
        Continue
      | CommandComplete ->
        (match Protocol.Backend.CommandComplete.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok tag ->
           (match !seen_copy_done with
            | false -> protocol_error_s [%sexp "CommandComplete before CopyDone?"]
            | true -> Stop (Ok tag)))
      | msg_type -> unexpected_msg_type msg_type [%sexp "draining copy-out mode"])
  ;;

  let abort_copy_in t ~reason =
    catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
      Protocol.Frontend.Writer.copy_fail writer { reason });
    read_messages t ~handle_message:(fun msg_type iobuf ->
      match msg_type with
      | ErrorResponse ->
        (match Protocol.Backend.ErrorResponse.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok _ -> Stop ())
      | msg_type -> unexpected_msg_type msg_type [%sexp "aborting copy-in mode"])
  ;;

  let close_unnamed_portal_and_statement_and_sync_after_query t =
    catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
      (* Closing the portal & statement is not strictly necessary. The Portal is closed
         anyway when the current transaction ends (be it due to the sync message, or the
         COMMIT if we're inside a BEGIN/END block), and they're implicitly closed (before
         being re-opened) when the unnamed portal/statement is next used (e.g., by the
         next query). However, doing so frees resources more eagerly, which is good. *)
      Protocol.Frontend.Writer.close writer (Portal Types.Portal_name.unnamed);
      (* Note that closing a statement implicitly closes any open portals that were
         constructed from it. *)
      Protocol.Frontend.Writer.close writer (Statement Types.Statement_name.unnamed);
      (* The sync message obviates the need for a flush message.
         Note that if we're not within a BEGIN/END block, this commits the transaction. *)
      Protocol.Frontend.Writer.sync writer);
    read_messages t ~handle_message:(fun msg_type iobuf ->
      match msg_type with
      | CloseComplete ->
        Protocol.Backend.CloseComplete.consume iobuf;
        Continue
      | ReadyForQuery ->
        (match Protocol.Backend.ReadyForQuery.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok (Idle | In_transaction | In_failed_transaction) -> Stop ())
      | ErrorResponse ->
        (match Protocol.Backend.ErrorResponse.consume iobuf with
         | Error err -> protocol_error_of_error err
         | Ok err ->
           let err =
             Pgasync_error.of_error_response err
             |> Pgasync_error.tag ~tag:"response to close/sync was an error"
           in
           (* The "message flow" part of the postgres protocol docs says:

              It is not an error to issue Close against a nonexistent statement or portal
              name. The response is normally CloseComplete, but could be ErrorResponse if
              some difficulty is encountered while releasing resources.

              We therefore treat ErrorResponse here as "the backend is hosed, kill the
              connection". *)
           Protocol_error err)
      | msg_type -> unexpected_msg_type msg_type [%sexp "synchronising after query"])
  ;;

  let internal_query
        t
        ?(parameters = [||])
        ?pushback
        ~handle_columns
        query_string
        ~handle_row
    =
    let%bind result =
      match%bind parse_and_start_executing_query t query_string ~parameters with
      | Connection_closed _ as err -> return err
      | Done About_to_copy_out ->
        let%bind (Connection_closed _ | Done _) = drain_copy_out t in
        return
          (Done
             (Or_pgasync_error.error_s
                [%message "COPY TO STDOUT is not appropriate for [Postgres_async.query]"]))
      | Done (Ready_to_copy_in _) ->
        let reason = "COPY FROM STDIN is not appropriate for [Postgres_async.query]" in
        let%bind (Connection_closed _ | Done ()) = abort_copy_in t ~reason in
        return (Done (Or_pgasync_error.error_string reason))
      | Done (Remote_reported_error error) -> return (Done (Error error))
      | Done Empty_query -> return (Done (Ok Protocol.Backend.CommandComplete.Empty_query))
      | Done (Command_complete_without_output tag) ->
         (* og edit: always call handle_columns even if there is no data. The empty array
                     indicates to the caller that there will be no rows *)
         handle_columns [||];
         return (Done (Ok tag))
      | Done (About_to_deliver_rows description) ->
        handle_columns description;
        let column_names = Array.map description ~f:Column_metadata.name in
        read_datarows t ~pushback ~f:(fun ~datarow_iobuf:iobuf ->
          match Protocol.Backend.DataRow.consume iobuf with
          | Error err -> protocol_error_of_error err
          | Ok values ->
            (match Array.length values = Array.length column_names with
             | false ->
               protocol_error_s
                 [%message
                   "number of columns in DataRow message did not match RowDescription"
                     (column_names : string array)
                     (values : string option array)]
             | true ->
               handle_row ~column_names ~values;
               Continue))
    in
    (* Note that if we're not within a BEGIN/END block, this commits the transaction. *)
    let%bind sync_result = close_unnamed_portal_and_statement_and_sync_after_query t in
    match result, sync_result with
    | Connection_closed err, _ | Done (Error err), _ | _, Connection_closed err ->
      return (Error err)
    | Done (Ok res), Done () -> return (Ok res)
  ;;

  (* [query] wraps [internal_query], acquiring the sequencer lock and keeping the user's
     exceptions away from trashing our state. *)
  let query t ?parameters ?pushback ?handle_columns query_string ~handle_row =
    let callback_raised = ref false in
    let wrap_callback ~f =
      match !callback_raised with
      | true -> ()
      | false ->
        (match f () with
         | () -> ()
         | exception exn ->
           (* it's important that we drain (and discard) the remaining rows. *)
           Monitor.send_exn (Monitor.current ()) exn;
           callback_raised := true)
    in
    let handle_columns description =
      match handle_columns with
      | None -> ()
      | Some handler -> wrap_callback ~f:(fun () -> handler description)
    in
    let handle_row ~column_names ~values =
      wrap_callback ~f:(fun () -> handle_row ~column_names ~values)
    in
    let%bind result =
      Query_sequencer.enqueue t.sequencer (fun () ->
        internal_query t ?parameters ?pushback ~handle_columns query_string ~handle_row)
    in
    match !callback_raised with
    | true -> Deferred.never ()
    | false -> return result
  ;;

  (* [query_expect_no_data] doesn't need the separation that [internal_query] and [query]
     have because there's no callback to wrap and it's easy enough to just throw the
     sequencer around the whole function. *)
  let query_expect_no_data t ?(parameters = [||]) query_string =
    Query_sequencer.enqueue t.sequencer (fun () ->
      let%bind result =
        match%bind parse_and_start_executing_query t query_string ~parameters with
        | Connection_closed _ as err -> return err
        | Done About_to_copy_out ->
          let%bind (Connection_closed _ | Done _) = drain_copy_out t in
          return
            (Done
               (Or_pgasync_error.error_s
                  [%message
                    "[Postgres_async.query_expect_no_data]: query attempted COPY OUT"]))
        | Done (Ready_to_copy_in _) ->
          let reason =
            "[Postgres_async.query_expect_no_data]: query attempted COPY IN"
          in
          let%bind (Connection_closed _ | Done ()) = abort_copy_in t ~reason in
          return (Done (Or_pgasync_error.error_string reason))
        | Done (About_to_deliver_rows _) ->
          (match%bind drain_datarows t with
           | Connection_closed _ as err -> return err
           | Done (_, (Error err)) -> return (Done (Error err))
           | Done (0, (Ok tag)) -> return (Done (Ok tag))
           | Done _ ->
             return
               (Done
                  (Or_pgasync_error.error_s
                     [%message "query unexpectedly produced rows"])))
        | Done (Remote_reported_error error) -> return (Done (Error error))
        | Done Empty_query -> return (Done (Ok Protocol.Backend.CommandComplete.Empty_query))
        | Done (Command_complete_without_output tag) -> return (Done (Ok tag))
      in
      let%bind sync_result =
        close_unnamed_portal_and_statement_and_sync_after_query t
      in
      match result, sync_result with
      | Connection_closed err, _ | Done (Error err), _ | _, Connection_closed err ->
        return (Error err)
      | Done (Ok res), Done () -> return (Ok res))
  ;;

  let parse_and_start_executing_query_for_prepare t ~statement_name ~query_string =
    match t.state with
    | Failed { error; _ } ->
      (* See comment at top of file regarding erasing error codes from this error. *)
      return
        (Connection_closed
           (Pgasync_error.create_s
              [%message
                "query issued against previously-failed connection"
                  ~original_error:(error : Pgasync_error.t)]))
    | Closing | Closed_gracefully ->
      return
        (Connection_closed
           (Pgasync_error.of_string "query issued against connection closed by user"))
    | Open ->
      catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
        Protocol.Frontend.Writer.parse
          writer
          { destination = statement_name; query = query_string };
        );
      let state = ref Parsing in
      let unexpected_msg_type msg_type =
        unexpected_msg_type msg_type [%sexp (state : setup_loop_state ref)]
      in
      read_messages t ~handle_message:(fun msg_type iobuf ->
        match !state, msg_type with
        | state, ErrorResponse ->
          (match Protocol.Backend.ErrorResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok err ->
             let tag =
               sprintf !"Postgres Server Error (state=%{sexp:setup_loop_state})" state
             in
             let err = Pgasync_error.of_error_response err |> Pgasync_error.tag ~tag in
             Stop (Remote_reported_error err))
        | Parsing, ParseComplete ->
          let () = Protocol.Backend.ParseComplete.consume iobuf in
          Stop Empty_query
        | _, msg_type -> unexpected_msg_type msg_type)
  ;;

  let prepare t ~statement_name ~query_string =
    Query_sequencer.enqueue t.sequencer (fun () ->
      let%bind result =
        match%bind parse_and_start_executing_query_for_prepare t ~statement_name ~query_string with
        | Connection_closed _ as err -> return err
        | Done About_to_copy_out ->
          let%bind (Connection_closed _ | Done _) = drain_copy_out t in
          return
            (Done
               (Or_pgasync_error.error_s
                  [%message
                    "[Postgres_async.query_expect_no_data]: query attempted COPY OUT"]))
        | Done (Ready_to_copy_in _) ->
          let reason =
            "[Postgres_async.query_expect_no_data]: query attempted COPY IN"
          in
          let%bind (Connection_closed _ | Done ()) = abort_copy_in t ~reason in
          return (Done (Or_pgasync_error.error_string reason))
        | Done (About_to_deliver_rows _) ->
          (match%bind drain_datarows t with
           | Connection_closed _ as err -> return err
           | Done _ ->
             return
               (Done
                  (Or_pgasync_error.error_s
                     [%message "query unexpectedly produced rows"])))
        | Done (Remote_reported_error error) -> return (Done (Error error))
        | Done Empty_query -> return (Done (Ok Protocol.Backend.CommandComplete.Empty_query))
        | Done (Command_complete_without_output tag) -> return (Done (Ok tag))
      in
      let%bind sync_result =
        close_unnamed_portal_and_statement_and_sync_after_query t
      in
      match result, sync_result with
      | Connection_closed err, _ | Done (Error err), _ | _, Connection_closed err ->
        return (Error err)
      | Done (Ok res), Done () -> return (Ok res))
  ;;


  (* TODO: Skip Describe if we don't provide a handle_columns. Might be best to require
           a describe result from when we prepared the query. Note that the describe
           result from a prepare and a describe result from after a bind are slightly
           different (see 'portal variant' vs 'statement variant' in
           https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-ASYNC)
   *)
  let parse_and_start_executing_query_for_query_prepared t ~statement_name ~parameters =
    match t.state with
    | Failed { error; _ } ->
      (* See comment at top of file regarding erasing error codes from this error. *)
      return
        (Connection_closed
           (Pgasync_error.create_s
              [%message
                "query issued against previously-failed connection"
                  ~original_error:(error : Pgasync_error.t)]))
    | Closing | Closed_gracefully ->
      return
        (Connection_closed
           (Pgasync_error.of_string "query issued against connection closed by user"))
    | Open ->
      catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
        Protocol.Frontend.Writer.bind
          writer
          { destination = Types.Portal_name.unnamed
          ; statement = statement_name
          ; parameters
          };
        Protocol.Frontend.Writer.describe writer (Portal Types.Portal_name.unnamed);
        Protocol.Frontend.Writer.execute
          writer
          { portal = Types.Portal_name.unnamed; limit = Unlimited });
      let state = ref Binding in
      let unexpected_msg_type msg_type =
        unexpected_msg_type msg_type [%sexp (state : setup_loop_state ref)]
      in
      read_messages t ~handle_message:(fun msg_type iobuf ->
        match !state, msg_type with
        | state, ErrorResponse ->
          (match Protocol.Backend.ErrorResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok err ->
             let tag =
               sprintf !"Postgres Server Error (state=%{sexp:setup_loop_state})" state
             in
             let err = Pgasync_error.of_error_response err |> Pgasync_error.tag ~tag in
             Stop (Remote_reported_error err))
        | Parsing, msg_type -> unexpected_msg_type msg_type
        | Binding, BindComplete ->
          let () = Protocol.Backend.BindComplete.consume iobuf in
          state := Describing;
          Continue
        | Binding, msg_type -> unexpected_msg_type msg_type
        | Describing, RowDescription ->
          (match Protocol.Backend.RowDescription.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok description -> Stop (About_to_deliver_rows description))
        | Describing, NoData ->
          let () = Protocol.Backend.NoData.consume iobuf in
          state := Executing;
          Continue
        | Describing, msg_type -> unexpected_msg_type msg_type
        | Executing, EmptyQueryResponse ->
          let () = Protocol.Backend.EmptyQueryResponse.consume iobuf in
          Stop Empty_query
        | Executing, CommandComplete ->
          (match Protocol.Backend.CommandComplete.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok tag -> Stop (Command_complete_without_output tag))
        | Executing, CopyInResponse ->
          (match Protocol.Backend.CopyInResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok details -> Stop (Ready_to_copy_in details))
        | Executing, CopyOutResponse ->
          (match Protocol.Backend.CopyOutResponse.consume iobuf with
           | Error err -> protocol_error_of_error err
           | Ok _ -> Stop About_to_copy_out)
        | Executing, CopyBothResponse ->
          (* CopyBothResponse is only used for streaming replication, which we do not
             initiate. *)
          unexpected_msg_type msg_type
        | Executing, msg_type -> unexpected_msg_type msg_type)
  ;;


  let internal_query_prepared
        t
        ?(parameters = [||])
        ?pushback
        ~handle_columns
        ~handle_row
        statement_name
    =
    let%bind result =
      match%bind parse_and_start_executing_query_for_query_prepared ~statement_name t ~parameters with
      | Connection_closed _ as err -> return err
      | Done About_to_copy_out ->
        let%bind (Connection_closed _ | Done _) = drain_copy_out t in
        return
          (Done
             (Or_pgasync_error.error_s
                [%message "COPY TO STDOUT is not appropriate for [Postgres_async.query]"]))
      | Done (Ready_to_copy_in _) ->
        let reason = "COPY FROM STDIN is not appropriate for [Postgres_async.query]" in
        let%bind (Connection_closed _ | Done ()) = abort_copy_in t ~reason in
        return (Done (Or_pgasync_error.error_string reason))
      | Done (Remote_reported_error error) -> return (Done (Error error))
      | Done Empty_query -> return (Done (Ok Protocol.Backend.CommandComplete.Empty_query))
      | Done (Command_complete_without_output tag) ->
         handle_columns [||];
         return (Done (Ok tag))
      | Done (About_to_deliver_rows description) ->
        handle_columns description;
        let column_names = Array.map description ~f:Column_metadata.name in
        read_datarows t ~pushback ~f:(fun ~datarow_iobuf:iobuf ->
          match Protocol.Backend.DataRow.consume iobuf with
          | Error err -> protocol_error_of_error err
          | Ok values ->
            (match Array.length values = Array.length column_names with
             | false ->
               protocol_error_s
                 [%message
                   "number of columns in DataRow message did not match RowDescription"
                     (column_names : string array)
                     (values : string option array)]
             | true ->
               handle_row ~column_names ~values;
               Continue))
    in
    (* Note that if we're not within a BEGIN/END block, this commits the transaction. *)
    let%bind sync_result = close_unnamed_portal_and_statement_and_sync_after_query t in
    match result, sync_result with
    | Connection_closed err, _ | Done (Error err), _ | _, Connection_closed err ->
      return (Error err)
    | Done (Ok res), Done () -> return (Ok res)
  ;;


  (* [query] wraps [internal_query], acquiring the sequencer lock and keeping the user's
     exceptions away from trashing our state. *)
  let query_prepared t ?parameters ?pushback ?handle_columns statement_name ~handle_row =
    let callback_raised = ref false in
    let wrap_callback ~f =
      match !callback_raised with
      | true -> ()
      | false ->
        (match f () with
         | () -> ()
         | exception exn ->
           (* it's important that we drain (and discard) the remaining rows. *)
           Monitor.send_exn (Monitor.current ()) exn;
           callback_raised := true)
    in
    let handle_columns description =
      match handle_columns with
      | None -> ()
      | Some handler -> wrap_callback ~f:(fun () -> handler description)
    in
    let handle_row ~column_names ~values =
      wrap_callback ~f:(fun () -> handle_row ~column_names ~values)
    in
    let%bind result =
      Query_sequencer.enqueue t.sequencer (fun () ->
        internal_query_prepared t statement_name ?parameters ?pushback ~handle_columns ~handle_row)
    in
    match !callback_raised with
    | true -> Deferred.never ()
    | false -> return result
  ;;


  type 'a feed_data_result =
    | Abort of { reason : string }
    | Wait of unit Deferred.t
    | Data of 'a
    | Finished

  let query_did_not_initiate_copy_in =
    lazy
      (return
         (Done (Or_pgasync_error.error_s [%message "Query did not initiate copy-in mode"])))
  ;;

  (* [internal_copy_in_raw] is to [copy_in_raw] as [internal_query] is to [query].
     Sequencer and exception handling. *)
  let internal_copy_in_raw t ?(parameters = [||]) query_string ~feed_data =
    let%bind result =
      match%bind parse_and_start_executing_query t query_string ~parameters with
      | Connection_closed _ as err -> return err
      | Done About_to_copy_out ->
        let%bind (Connection_closed _ | Done _) = drain_copy_out t in
        return
          (Done
             (Or_pgasync_error.error_s
                [%message "COPY TO STDOUT is not appropriate for [Postgres_async.query]"]))
      | Done (Empty_query | Command_complete_without_output _) ->
        force query_did_not_initiate_copy_in
      | Done (About_to_deliver_rows _) ->
        let%bind (Connection_closed _ | Done _) = drain_datarows t in
        force query_did_not_initiate_copy_in
      | Done (Remote_reported_error error) -> return (Done (Error error))
      | Done (Ready_to_copy_in _) ->
        let sent_copy_done = ref false in
        let (response_deferred : Protocol.Backend.CommandComplete.t Or_pgasync_error.t read_messages_result Deferred.t) =
          read_messages t ~handle_message:(fun msg_type iobuf ->
            match msg_type with
            | ErrorResponse ->
              (match Protocol.Backend.ErrorResponse.consume iobuf with
               | Error err -> protocol_error_of_error err
               | Ok err -> Stop (Error (Pgasync_error.of_error_response err)))
            | CommandComplete ->
              (match Protocol.Backend.CommandComplete.consume iobuf with
               | Error err -> protocol_error_of_error err
               | Ok tag ->
                 (match !sent_copy_done with
                  | false ->
                    protocol_error_s
                      [%sexp "CommandComplete response before we sent CopyDone?"]
                  | true -> Stop (Ok tag)))
             | msg_type -> unexpected_msg_type msg_type [%sexp "copying in"])
        in
        let%bind () =
          let rec loop () =
            match feed_data () with
            | Abort { reason } ->
              catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
                Protocol.Frontend.Writer.copy_fail writer { reason });
              return ()
            | Wait deferred -> continue ~after:deferred
            | Data payload ->
              catch_write_errors t ~flush_message:Not_required ~f:(fun writer ->
                Protocol.Frontend.Writer.copy_data writer payload);
              (match bytes_pending_in_writer_buffer t > 128 * 1024 * 1024 with
               | false -> loop ()
               | true -> continue ~after:(wait_for_writer_buffer_to_be_empty t))
            | Finished ->
              sent_copy_done := true;
              catch_write_errors t ~flush_message:Write_afterwards ~f:(fun writer ->
                Protocol.Frontend.Writer.copy_done writer);
              return ()
          and continue ~after =
            let%bind () = after in
            (* check for early termination; not necessary for correctness, just nice. *)
            match Deferred.peek response_deferred with
            | None -> loop ()
            | Some (Connection_closed _ | Done (Error _)) -> return ()
            | Some (Done (Ok _)) ->
              failwith
                "BUG: response_deferred is (Done (Ok ())), but we never set \
                 !sent_copy_done?"
          in
          loop ()
        in
        response_deferred
    in
    let%bind sync_result = close_unnamed_portal_and_statement_and_sync_after_query t in
    match result, sync_result with
    | Connection_closed err, _ | Done (Error err), _ | _, Connection_closed err ->
      return (Error err)
    | Done (Ok res), Done () -> return (Ok res)
  ;;

  let copy_in_raw t ?parameters query_string ~feed_data =
    let callback_raised = ref false in
    let feed_data () =
      (* We shouldn't be called again after [Abort] *)
      assert (not !callback_raised);
      match feed_data () with
      | (Abort _ | Wait _ | Data _ | Finished) as x -> x
      | exception exn ->
        Monitor.send_exn (Monitor.current ()) exn;
        callback_raised := true;
        Abort { reason = "feed_data callback raised" }
    in
    let%bind result =
      Query_sequencer.enqueue t.sequencer (fun () ->
        internal_copy_in_raw t ?parameters query_string ~feed_data)
    in
    match !callback_raised with
    | true -> Deferred.never ()
    | false -> return result
  ;;

  (* [copy_in_rows] builds on [copy_in_raw] and clearly doesn't raise exceptions in the
     callback wrapper, so we can just rely on [copy_in_raw] to handle sequencing and
     exceptions here. *)
  let copy_in_rows t ~table_name ~column_names ~feed_data =
    let query_string = String_escaping.Copy_in.query ~table_name ~column_names in
    copy_in_raw t query_string ~feed_data:(fun () ->
      match feed_data () with
      | (Abort _ | Wait _ | Finished) as x -> x
      | Data row -> Data (String_escaping.Copy_in.row_to_string row))
  ;;

  let listen_to_notifications t ~channel ~f =
    let query = String_escaping.Listen.query ~channel in
    let channel = Notification_channel.of_string channel in
    let bus = notification_bus t channel in
    let monitor = Monitor.current () in
    let subscriber =
      Bus.subscribe_exn
        bus
        [%here]
        ~f:(fun pid payload -> f ~pid ~payload)
        ~on_callback_raise:(fun error -> Monitor.send_exn monitor (Error.to_exn error))
    in
    ignore (subscriber : _ Bus.Subscriber.t);
    Deferred.Result.map ~f:(fun _ -> ()) (query_expect_no_data t query)
  ;;
end

type t = Expert.t [@@deriving sexp_of]

let connect ?interrupt ?ssl_mode ?server ?user ?password ?gss_krb_token ~database () =
  Expert.connect ?interrupt ?ssl_mode ?server ?user ?password ?gss_krb_token ~database ()
  >>| Or_pgasync_error.to_or_error
;;

let close t = Expert.close t >>| Or_pgasync_error.to_or_error
let close_finished t = Expert.close_finished t >>| Or_pgasync_error.to_or_error

type state =
  | Open
  | Closing
  | Failed of
      { error : Error.t
      ; resources_released : bool
      }
  | Closed_gracefully
[@@deriving sexp_of]

let status t =
  match Expert.status t with
  | Failed { error; resources_released } ->
    Failed { error = Pgasync_error.to_error error; resources_released }
  | Open -> Open
  | Closing -> Closing
  | Closed_gracefully -> Closed_gracefully
;;

let with_connection
      ?interrupt
      ?ssl_mode
      ?server
      ?user
      ?password
      ?gss_krb_token
      ~database
      ~on_handler_exception:`Raise
      func
  =
  Expert.with_connection
    ?interrupt
    ?ssl_mode
    ?server
    ?user
    ?password
    ?gss_krb_token
    ~database
    ~on_handler_exception:`Raise
    func
  >>| Or_pgasync_error.to_or_error
;;

type 'a feed_data_result = 'a Expert.feed_data_result =
  | Abort of { reason : string }
  | Wait of unit Deferred.t
  | Data of 'a
  | Finished

let copy_in_raw t ?parameters query_string ~feed_data =
  Expert.copy_in_raw t ?parameters query_string ~feed_data
  >>| Or_pgasync_error.to_or_error
;;

let copy_in_rows t ~table_name ~column_names ~feed_data =
  Expert.copy_in_rows t ~table_name ~column_names ~feed_data
  >>| Or_pgasync_error.to_or_error
;;

let listen_to_notifications t ~channel ~f =
  Expert.listen_to_notifications t ~channel ~f >>| Or_pgasync_error.to_or_error
;;

let query_expect_no_data t ?parameters query_string =
  Expert.query_expect_no_data t ?parameters query_string >>| Or_pgasync_error.to_or_error
;;

let query t ?parameters ?pushback ?handle_columns query_string ~handle_row =
  Expert.query t ?parameters ?pushback ?handle_columns query_string ~handle_row
  >>| Or_pgasync_error.to_or_error
;;

let prepare t ~statement_name ~query_string =
  Expert.prepare t ~statement_name ~query_string
  >>| Or_pgasync_error.to_or_error
;;

let query_prepared t ?parameters ?pushback ?handle_columns statement_name ~handle_row =
  Expert.query_prepared t ?parameters ?pushback ?handle_columns statement_name ~handle_row
  >>| Or_pgasync_error.to_or_error
;;

module Private = struct
  let pgasync_error_of_error = Pgasync_error.of_error
end
