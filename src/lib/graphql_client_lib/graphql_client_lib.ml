open Core
open Async
open Signature_lib

module type Config_intf = sig
  val address : string

  val headers : string String.Map.t

  val preprocess_variables_string : string -> string
end

let make_local_uri port address =
  Uri.of_string ("http://localhost:" ^ string_of_int port ^/ address)

module type S = sig
  val query_or_error :
       < parse: Yojson.Basic.json -> 'response
       ; query: string
       ; variables: Yojson.Basic.json >
    -> int
    -> 'response Deferred.Or_error.t

  val query :
       < parse: Yojson.Basic.json -> 'response
       ; query: string
       ; variables: Yojson.Basic.json >
    -> int
    -> 'response Deferred.t
end

let graphql_error_to_string e =
  let error_obj_to_string obj =
    let open Yojson.Basic in
    let obj_message =
      let open Option.Let_syntax in
      let%bind message = Util.to_option (Util.member "message") obj in
      let%map path = Util.to_option (Util.member "path") obj in
      let message =
        Util.to_string_option message
        |> Option.value ~default:(Yojson.Basic.to_string message)
      in
      Printf.sprintf "%s (in %s)" message (Yojson.Basic.to_string path)
    in
    match obj_message with Some m -> m | None -> to_string obj
  in
  match e with
  | `List l ->
      List.map ~f:error_obj_to_string l |> String.concat ~sep:"\n"
  | e ->
      error_obj_to_string e

module Connection_error = struct
  type t = [`Failed_request of Error.t | `Graphql_error of Error.t]

  let ok_exn = function
    | `Failed_request e ->
        eprintf "❌ Error connecting to graphql server. Error message: %s\n%!"
          e ;
        exit 17
    | `Graphql_error e ->
        eprintf "❌ Error: %s\n" e ;
        exit 17

  let to_error = function
    | `Failed_request e ->
        Error.createf !"Failed Request: %s" e
    | `Graphql_error e ->
        Error.createf !"Graphql error: %s" e
end

module Make (Config : Config_intf) = struct
  let local_uri port = make_local_uri port Config.address

  let query_or_error query_obj port =
    let variables_string =
      Config.preprocess_variables_string
      @@ Yojson.Basic.to_string query_obj#variables
    in
    let body_string =
      Printf.sprintf {|{"query": "%s", "variables": %s}|} query_obj#query
        variables_string
    in
    let open Deferred.Result.Let_syntax in
    let headers =
      List.fold ~init:(Cohttp.Header.init ())
        (("Accept", "application/json") :: Map.to_alist Config.headers)
        ~f:(fun header (key, value) -> Cohttp.Header.add header key value)
    in
    let%bind _, body =
      Deferred.Or_error.try_with ~extract_exn:true (fun () ->
          Cohttp_async.Client.post ~headers
            ~body:(Cohttp_async.Body.of_string body_string)
            (local_uri port) )
      |> Deferred.Result.map_error ~f:(fun e ->
             `Failed_request (Error.to_string_hum e) )
    in
    let%bind body_str =
      Cohttp_async.Body.to_string body |> Deferred.map ~f:Result.return
    in
    let body_json = Yojson.Basic.from_string body_str in
    let open Yojson.Basic.Util in
    ( match (member "errors" body_json, member "data" body_json) with
    | `Null, `Null ->
        Error (`Graphql_error "Empty response from graphql query")
    | error, `Null ->
        Error (`Graphql_error (graphql_error_to_string error))
    | _, data ->
        Result.try_with (fun () -> query_obj#parse data)
        |> Result.map_error ~f:(fun e ->
               `Graphql_error
                 (Printf.sprintf
                    "Problem parsing graphql response\nError message: %s"
                    (Exn.to_string e)) ) )
    |> Deferred.return

  let query query_obj port =
    let open Deferred.Let_syntax in
    match%bind query_or_error query_obj port with
    | Ok r ->
        Deferred.return r
    | Error error ->
        Connection_error.ok_exn error
end

module Encoders = struct
  let optional = Option.value_map ~default:`Null

  let uint64 value = `String (Unsigned.UInt64.to_string value)

  let amount value = `String (Currency.Amount.to_string value)

  let fee value = `String (Currency.Fee.to_string value)

  let nonce value = `String (Coda_base.Account.Nonce.to_string value)

  let uint32 value = `String (Unsigned.UInt32.to_string value)

  let public_key value = `String (Public_key.Compressed.to_base58_check value)
end

module Decoders = struct
  let optional ~f = function `Null -> None | json -> Some (f json)

  let public_key json =
    Yojson.Basic.Util.to_string json
    |> Public_key.Compressed.of_base58_check_exn

  let optional_public_key = Option.map ~f:public_key

  let uint64 json =
    Yojson.Basic.Util.to_string json |> Unsigned.UInt64.of_string
end