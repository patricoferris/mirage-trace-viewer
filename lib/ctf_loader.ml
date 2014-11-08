(* Copyright (C) 2014, Thomas Leonard *)

open Event
open Bigarray

type log_buffer = (char, int8_unsigned_elt, c_layout) Array1.t

let thread_type_of_int = function
  | 0 -> "Wait"
  | 1 -> "Task"
  | 2 -> "Bind"
  | 3 -> "Try"
  | 4 -> "Choose"
  | 5 -> "Pick"
  | 6 -> "Join"
  | 7 -> "Map"
  | 8 -> "Condition"
  | _ -> assert false

let uuid = "\x05\x88\x3b\x8d\x52\x1a\x48\x7b\xb3\x97\x45\x6a\xb1\x50\x68\x0c"

type packet = {
  mutable packet_counter : int;
  packet_data : log_buffer;
}

let order_packets = function
  | [] -> []
  | (first :: _) as packets ->
  (* When the packet counter suddently drops, there are two possibilities:
   * - we wrapped back to -2^15 and this is the next packet
   * - the next packet is the earliest in the ring *)
  let prev_count = ref first.packet_counter in
  let earliest_packet =
    try
      packets |> List.find (fun packet ->
        let diff = (packet.packet_counter - !prev_count) land 0xffff in
        prev_count := packet.packet_counter;
        diff > 0x8000   (* Large jump => this is not the next packet, but the first *)
      )
    with Not_found -> first in
  (* Printf.printf "Earliest packet is 0x%x\n" earliest_packet.packet_counter; *)
  let base_counter = earliest_packet.packet_counter in
  packets
  |> List.map (fun p -> {p with packet_counter = (p.packet_counter - base_counter) land 0xffff})
  |> List.sort (fun a b -> compare a.packet_counter b.packet_counter)
  |> List.map (fun p -> p.packet_data)

let packets data =
  let rec aux packet_start =
    if packet_start = Array1.dim data then []
    else (
      (* Printf.printf "Read header at %d\n" !pos; *)
      let magic = EndianBigstring.LittleEndian.get_int32 data packet_start in
      if magic <> 0xc1fc1fc1l then failwith "Not a CTF log packet (bad magic)";
      for i = 0 to 15 do
        if Array1.get data (packet_start + 4 + i) <> uuid.[i] then failwith "Packet UUID doesn't match!"
      done;
      let packet_size = EndianBigstring.LittleEndian.get_int32 data (packet_start + 20) |> Int32.to_int in
      let packet_counter = EndianBigstring.LittleEndian.get_uint16 data (packet_start + 24) in
      let packet_content_size = EndianBigstring.LittleEndian.get_int32 data (packet_start + 26) |> Int32.to_int in
      let header_length = 30 in
      let first_event = packet_start + header_length in
      let packet_data = Array1.sub data first_event (packet_content_size / 8 - header_length) in
      let item = {packet_counter; packet_data} in
      Printf.printf "Found packet 0x%x at offset %d\n" packet_counter packet_start;
      item :: aux (packet_start + packet_size / 8)
    ) in
  order_packets (aux 0)

let from_channel ch =
  let fd = Unix.descr_of_in_channel ch in
  let size = Unix.((fstat fd).st_size) in
  let stream_data = Array1.map_file fd char c_layout false size in

  let events = ref [] in

  packets stream_data |> List.iter (fun data ->
    let pos = ref 0 in
    let read64 () =
      let v = EndianBigstring.LittleEndian.get_int64 data !pos in
      pos := !pos + 8;
      v in
    let read8 () =
      let v = EndianBigstring.LittleEndian.get_int8 data !pos in
      pos := !pos + 1;
      v in
    let read_thread () =
      read64 () |> Int64.to_int in    (* FIXME: will fail on 32-bit platforms *)
    let read_string () =
      let b = Buffer.create 10 in
      let rec aux i =
        match EndianBigstring.LittleEndian.get_char data i with
        | '\x00' -> pos := i + 1; Buffer.contents b
        | x -> Buffer.add_char b x; aux (i + 1) in
      aux !pos in

    while !pos < Array1.dim data do
      let time = read64 () in
      let op =
        match read8 () with
        | 0 ->
            let parent = read_thread () in
            let child = read_thread () in
            let thread_type = read8 () in
            Creates (parent, child, thread_type_of_int thread_type)
        | 1 ->
            let reader = read_thread () in
            let input = read_thread () in
            Reads (reader, input)
        | 2 ->
            let resolver = read_thread () in
            let thread = read_thread () in
            Resolves (resolver, thread, None)
        | 3 ->
            let resolver = read_thread () in
            let thread = read_thread () in
            let ex = read_string () in
            Resolves (resolver, thread, Some ex)
        | 4 ->
            let bind = read_thread () in
            let thread = read_thread () in
            Becomes (bind, thread)
        | 5 ->
            let thread = read_thread () in
            let label = read_string () in
            Label (thread, label)
        | 6 ->
            let thread = read_thread () in
            let amount = read64 () |> Int64.to_int in
            let counter = read_string () in
            Increases (thread, counter, amount)
        | 7 ->
            let thread = read_thread () in
            Switch thread
        | 8 ->
            let duration = read64 () in
            Gc (Int64.to_float duration /. 1_000_000_000.)
        | x -> failwith (Printf.sprintf "Unknown event op %d" x) in
      let event = {
        time = Int64.to_float time /. 1_000_000_000.;
        op;
      } in
      events := event :: !events
    done;
  );
  List.rev !events
