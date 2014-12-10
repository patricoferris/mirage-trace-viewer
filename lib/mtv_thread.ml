(* Copyright (C) 2014, Thomas Leonard *)

type interaction = Resolve | Read | Signal

type time = float

type t = {
  thread_type : string;
  tid : int;
  mutable show_creation : bool;
  mutable start_time : time;
  mutable resolved : bool;
  mutable end_time : time;
  mutable creates : t list;
  mutable becomes : t option;
  mutable labels : (time * string) list;
  mutable interactions : (time * interaction * t) list;
  mutable activations : (time * time) list;
  mutable failure : string option;
  mutable y : float;
  mutable last_signalled : time;  (* (used to calculate end_time) *)
}

type mutable_counter = {
  mutable mc_values : (time * int) list;
}

type vat = {
  top_thread : t;
  mutable gc : (time * time) list;
  mutable counters : Mtv_counter.t list;
}

(* For threads with no end. Call before we reverse the lists. *)
let last_event_time t =
  let last = ref (max t.start_time t.last_signalled) in
  begin match t.creates with
  | child :: _ -> last := max !last child.start_time
  | _ -> () end;
  begin match t.becomes with
  | Some child -> last := max !last child.start_time
  | None -> () end;
  begin match t.labels with
  | (time, _) :: _ -> last := max !last time
  | _ -> () end;
  begin match t.interactions with
  | (time, _, _) :: _ -> last := max !last time
  | _ -> () end;
  begin match t.activations with
  | (_, time) :: _ -> last := max !last time
  | _ -> () end;
  !last

let make_thread ~tid ~start_time ~thread_type = {
  thread_type;
  tid;
  start_time;
  show_creation = true;
  end_time = infinity;
  creates = [];
  becomes = None;
  labels = [];
  interactions = [];
  activations = [];
  failure = None;
  resolved = false;
  y = -.infinity;
  last_signalled = -.infinity;
}

let rec iter fn thread =
  fn thread;
  thread.creates |> List.iter (iter fn)

let counter_value c =
  match c.mc_values with
  | [] -> 0
  | (_, v) :: _ -> v

(** Time of first interaction.
 * None if there isn't one, of if a label occurs first. *)
let first_interaction t =
  let rec aux = function
    | [] -> None
    | [i] -> Some i
    | _::xs -> aux xs in
  let i = aux t.interactions in
  match t.labels, i with
  | ((l_time, _) :: _), Some (i_time, _, _) when l_time < i_time -> None
  | _ -> i

(** If a bind-type thread's parent is still alive when it wakes up,
 * adjust its start time to its wake up time. This reduces visual clutter. *)
let rec simplify_binds parent =
  let relocs = ref [] in
  parent.creates <- parent.creates |> List.filter (fun t ->
    simplify_binds t;
    begin match t.thread_type, parent.becomes with
    | _, Some became when became == t -> true
    | ("bind" | "try"), _ ->
        begin match first_interaction t with
        | Some (wake_time, Read, other) ->
            t.show_creation <- false;
            t.start_time <- wake_time;
            if other == parent then true
            else (
              relocs := (t, other) :: !relocs;
              false
            )
        | _ -> true end
    | _ -> true end;
  );
  !relocs |> List.iter (fun (t, other) ->
    other.creates <- t :: other.creates;
  )

let of_events ?(simplify=true) events =
  let trace_start_time =
    match events with
    | [] -> failwith "No events!"
    | hd :: _ -> Mtv_event.(hd.time) in
  let top_thread = make_thread ~start_time:0.0 ~tid:(-1) ~thread_type:"preexisting" in
  top_thread.end_time <- 0.0;

  let vat = {top_thread; gc = []; counters = []} in

  let counters = Hashtbl.create 2 in
  let get_counter name =
    try Hashtbl.find counters name
    with Not_found ->
      let c = { mc_values = [] } in
      Hashtbl.add counters name c;
      c in

  let rec replacement thread =
    match thread.becomes with
    | None -> thread
    | Some t2 -> replacement t2 in

  let threads = Hashtbl.create 100 in
  Hashtbl.add threads (-1) top_thread;
  let get_thread tid =
    try Hashtbl.find threads tid |> replacement
    with Not_found ->
      let t = make_thread ~tid ~start_time:0.0 ~thread_type:"preexisting" in
      Hashtbl.add threads tid t;
      top_thread.creates <- t :: top_thread.creates;
      t in

  let running_thread = ref None in
  let switch time next =
    match !running_thread, next with
    | Some (_, prev), Some next when prev.tid = next.tid -> ()
    | prev, next ->
        begin match prev with
        | Some (start_time, prev) ->
            let end_time = min time (prev.end_time) in
            prev.activations <- (start_time, end_time) :: prev.activations
        | None -> () end;
        match next with
        | Some next -> running_thread := Some (time, next)
        | None -> running_thread := None in

  events |> List.iter (fun ev ->
    let open Mtv_event in
    let time = ev.time -. trace_start_time in
    if time > top_thread.end_time then top_thread.end_time <- time;

    match ev.op with
    | Creates (a, b, thread_type) ->
        let a = get_thread a in
        assert (not (Hashtbl.mem threads b));
        let child = make_thread ~start_time:time ~tid:b ~thread_type:(String.lowercase thread_type) in
        Hashtbl.add threads b child;
        a.creates <- child :: a.creates
    | Resolves (a, b, failure) ->
        let a = get_thread a in
        let b = get_thread b in
        a.interactions <- (time, Resolve, b) :: a.interactions;
        b.failure <- failure;
        b.end_time <- time;
        b.resolved <- true
    | Becomes (a, b) ->
        let a = get_thread a in
        a.end_time <- time;
        a.resolved <- true;
        assert (a.becomes = None);
        let b = Some (get_thread b) in
        a.becomes <- b;
        begin match !running_thread with
        | Some (_t, current_thread) when current_thread.tid = a.tid -> switch time b
        | _ -> () end
    | Reads (a, b) ->
        let a = get_thread a in
        let b = get_thread b in
        switch time (Some a);
        a.interactions <- (time, Read, b) :: a.interactions;
    | Signals (a, b) ->
        let a = get_thread a in
        let b = get_thread b in
        a.interactions <- (time, Signal, b) :: a.interactions;
        b.last_signalled <- time;
    | Label (a, msg) ->
        if a <> -1 then (
          let a = get_thread a in
          a.labels <- (time, msg) :: a.labels
        )
    | Switch a ->
        switch time (Some (get_thread a))
    | Gc duration ->
        vat.gc <- (time -. duration, time) :: vat.gc
    | Increases (a, counter, amount) ->
        let c = get_counter counter in
        let new_value = counter_value c + amount in
        c.mc_values <- (time, new_value) :: c.mc_values;
        let a = get_thread a in
        a.labels <- (time, Printf.sprintf "%s%+d" counter amount) :: a.labels
  );
  switch top_thread.end_time None;
  top_thread |> iter (fun t ->
    let labels =
      match t.failure with
      | None -> t.labels
      | Some failure -> (t.end_time, failure) :: t.labels in
    if t.end_time = infinity then (
      (* It probably got GC'd, but we don't see that. Make it disappear soon after its last event. *)
      t.end_time <- last_event_time t +. 0.000_001;
    );
    t.labels <- List.rev labels;
  );
  if simplify then simplify_binds top_thread;
  top_thread |> iter (fun t ->
    if t.labels = [] then t.labels <- [t.start_time, string_of_int t.tid]
  );
  counters |> Hashtbl.iter (fun name mc ->
    let values = List.rev mc.mc_values |> List.map (fun (t, v) -> (t, float_of_int v)) |> Array.of_list in
    let low = ref 0. in
    let high = ref 0. in
    values |> Array.iter (fun (_, v) ->
      low := min !low v;
      high := max !high v;
    );
    let counter = { Mtv_counter.
      name;
      values;
      min = !low;
      max = !high;
    } in
    vat.counters <- counter :: vat.counters
  );
  (* Create pre-existing threads in thread order, not the order we first saw them. *)
  let by_thread_id a b = compare a.tid b.tid in
  top_thread.creates <- List.sort by_thread_id top_thread.creates;
  vat

let top_thread v = v.top_thread
let gc_periods v = v.gc

let thread_type t = t.thread_type
let start_time t = t.start_time
let end_time t = t.end_time
let creates t = t.creates
let becomes t = t.becomes
let labels t = t.labels
let interactions t = t.interactions
let activations t = t.activations
let failure t = t.failure
let y t = t.y
let id t = t.tid
let resolved t = t.resolved
let show_creation t = t.show_creation

let set_y t y = t.y <- y

(** Sorts by y first, then by thread ID *)
let compare a b =
  match compare a.y b.y with
  | 0 -> compare a.tid b.tid
  | r -> r

let counters vat = vat.counters
