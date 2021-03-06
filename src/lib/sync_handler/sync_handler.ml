open Core_kernel
open Async
open Coda_base
open Coda_transition

module type Inputs_intf = sig
  module Transition_frontier : module type of Transition_frontier

  module Best_tip_prover :
    Coda_intf.Best_tip_prover_intf
    with type transition_frontier := Transition_frontier.t
end

module Make (Inputs : Inputs_intf) :
  Coda_intf.Sync_handler_intf
  with type transition_frontier := Inputs.Transition_frontier.t = struct
  open Inputs

  let find_in_root_history frontier state_hash =
    let open Transition_frontier.Extensions in
    let root_history =
      get_extension (Transition_frontier.extensions frontier) Root_history
    in
    Root_history.lookup root_history state_hash

  let get_breadcrumb_ledgers frontier =
    List.map (Transition_frontier.all_breadcrumbs frontier)
      ~f:(fun breadcrumb ->
        Transition_frontier.Breadcrumb.staged_ledger breadcrumb
        |> Staged_ledger.ledger
        |> Ledger.Any_ledger.cast (module Ledger) )

  let get_ledger_by_hash ~frontier ledger_hash =
    let ledger_breadcrumbs =
      Sequence.of_lazy
        (lazy (Sequence.of_list @@ get_breadcrumb_ledgers frontier))
    in
    let root_ledger =
      Ledger.Any_ledger.cast
        (module Ledger.Db)
        (Transition_frontier.root_snarked_ledger frontier)
    in
    Sequence.append (Sequence.singleton root_ledger) ledger_breadcrumbs
    |> Sequence.find ~f:(fun ledger ->
           Ledger_hash.equal
             (Ledger.Any_ledger.M.merkle_root ledger)
             ledger_hash )

  let answer_query :
         frontier:Inputs.Transition_frontier.t
      -> Ledger_hash.t
      -> Sync_ledger.Query.t Envelope.Incoming.t
      -> logger:Logger.t
      -> trust_system:Trust_system.t
      -> Sync_ledger.Answer.t Option.t Deferred.t =
   fun ~frontier hash query ~logger ~trust_system ->
    match get_ledger_by_hash ~frontier hash with
    | None ->
        return None
    | Some ledger ->
        let responder =
          Sync_ledger.Any_ledger.Responder.create ledger ignore ~logger
            ~trust_system
        in
        Sync_ledger.Any_ledger.Responder.answer_query responder query

  let get_staged_ledger_aux_and_pending_coinbases_at_hash ~frontier state_hash
      =
    let open Option.Let_syntax in
    Option.merge
      (let%map breadcrumb = Transition_frontier.find frontier state_hash in
       let staged_ledger =
         Transition_frontier.Breadcrumb.staged_ledger breadcrumb
       in
       let scan_state = Staged_ledger.scan_state staged_ledger in
       let merkle_root =
         Staged_ledger.hash staged_ledger |> Staged_ledger_hash.ledger_hash
       in
       let pending_coinbase =
         Staged_ledger.pending_coinbase_collection staged_ledger
       in
       (scan_state, merkle_root, pending_coinbase))
      (let%map root = find_in_root_history frontier state_hash in
       ( root.scan_state
       , root.staged_ledger_target_ledger_hash
       , root.pending_coinbase ))
      ~f:Fn.const

  let get_transition_chain ~frontier hashes =
    let open Option.Let_syntax in
    Option.all
    @@ List.map hashes ~f:(fun hash ->
           let%map validated_transition =
             Option.merge
               Transition_frontier.(
                 find frontier hash >>| Breadcrumb.validated_transition)
               (find_in_root_history frontier hash >>| fun x -> x.transition)
               ~f:Fn.const
           in
           External_transition.Validation.forget_validation
             validated_transition )

  module Root = struct
    let prove ~logger ~frontier seen_consensus_state =
      let open Option.Let_syntax in
      let%bind best_tip_with_witness =
        Best_tip_prover.prove ~logger frontier
      in
      let is_tip_better =
        Consensus.Hooks.select
          ~logger:
            (Logger.extend logger [("selection_context", `String "Root.prove")])
          ~existing:
            (External_transition.consensus_state best_tip_with_witness.data)
          ~candidate:seen_consensus_state
        = `Keep
      in
      let%map () = Option.some_if is_tip_better () in
      best_tip_with_witness

    let verify ~logger ~verifier observed_state peer_root =
      let open Deferred.Result.Let_syntax in
      let%bind ( (`Root _, `Best_tip (best_tip_transition, _)) as
               verified_witness ) =
        Best_tip_prover.verify ~verifier peer_root
      in
      let is_before_best_tip candidate =
        Consensus.Hooks.select
          ~logger:
            (Logger.extend logger [("selection_context", `String "Root.verify")])
          ~existing:
            (External_transition.consensus_state best_tip_transition.data)
          ~candidate
        = `Keep
      in
      let%map () =
        Deferred.return
          (Result.ok_if_true
             (is_before_best_tip observed_state)
             ~error:
               (Error.createf
                  !"Peer lied about it's best tip %{sexp:State_hash.t}"
                  best_tip_transition.hash))
      in
      verified_witness
  end

  module Bootstrappable_best_tip = struct
    let prove ~logger ~should_select_tip ~frontier clients_consensus_state =
      let open Option.Let_syntax in
      let%bind best_tip_with_witness =
        Best_tip_prover.prove ~logger frontier
      in
      let%map () =
        Option.some_if
          (should_select_tip ~existing:clients_consensus_state
             ~candidate:
               (External_transition.consensus_state best_tip_with_witness.data)
             ~logger:
               (Logger.extend logger
                  [ ( "selection_context"
                    , `String "Bootstrappable_best_tip.prove" ) ]))
          ()
      in
      best_tip_with_witness

    let verify ~logger ~should_select_tip ~verifier existing_state
        ( {Proof_carrying_data.data= best_tip; proof= _merkle_list, _root} as
        peer_best_tip ) =
      let open Deferred.Or_error.Let_syntax in
      let%bind () =
        Deferred.return
          (Result.ok_if_true
             ~error:
               (Error.of_string
                  "Peer's best tip did not cause you to bootstrap")
             (should_select_tip ~existing:existing_state
                ~candidate:(External_transition.consensus_state best_tip)
                ~logger:
                  (Logger.extend logger
                     [ ( "selection_context"
                       , `String "Bootstrappable_best_tip.verify" ) ])))
      in
      Best_tip_prover.verify ~verifier peer_best_tip

    module For_tests = struct
      let prove = prove

      let verify = verify
    end

    let prove = prove ~should_select_tip:Consensus.Hooks.should_bootstrap

    let verify = verify ~should_select_tip:Consensus.Hooks.should_bootstrap
  end
end

include Make (struct
  module Transition_frontier = Transition_frontier
  module Best_tip_prover = Best_tip_prover
end)

(* TODO: port these tests *)
(*
let%test_module "Sync_handler" =
  ( module struct
    let logger = Logger.null ()

    let hb_logger = Logger.create ()

    let pids = Child_processes.Termination.create_pid_table ()

    let trust_system = Trust_system.null ()

    let f_with_verifier ~f ~logger ~pids =
      let%map verifier = Verifier.create ~logger ~pids in
      f ~logger ~verifier

    let%test "sync with ledgers from another peer via glue_sync_ledger" =
      Backtrace.elide := false ;
      Printexc.record_backtrace true ;
      heartbeat_flag := true ;
      Ledger.with_ephemeral_ledger ~f:(fun dest_ledger ->
          Thread_safe.block_on_async_exn (fun () ->
              print_heartbeat hb_logger |> don't_wait_for ;
              let%bind frontier =
                create_root_frontier ~logger ~pids Genesis_ledger.accounts
              in
              let source_ledger =
                Transition_frontier.For_tests.root_snarked_ledger frontier
                |> Ledger.of_database
              in
              let desired_root = Ledger.merkle_root source_ledger in
              let sync_ledger =
                Sync_ledger.Mask.create dest_ledger ~logger ~trust_system
              in
              let query_reader = Sync_ledger.Mask.query_reader sync_ledger in
              let answer_writer = Sync_ledger.Mask.answer_writer sync_ledger in
              let peer =
                Network_peer.Peer.create Unix.Inet_addr.localhost
                  ~discovery_port:0 ~communication_port:1
              in
              let network =
                Network.create_stub ~logger
                  ~ip_table:
                    (Hashtbl.of_alist_exn
                       (module Unix.Inet_addr)
                       [(peer.host, frontier)])
                  ~peers:(Hash_set.of_list (module Network_peer.Peer) [peer])
              in
              Network.glue_sync_ledger network query_reader answer_writer ;
              match%map
                Sync_ledger.Mask.fetch sync_ledger desired_root ~data:()
                  ~equal:(fun () () -> true)
              with
              | `Ok synced_ledger ->
                  heartbeat_flag := false ;
                  Ledger_hash.equal
                    (Ledger.merkle_root dest_ledger)
                    (Ledger.merkle_root source_ledger)
                  && Ledger_hash.equal
                       (Ledger.merkle_root synced_ledger)
                       (Ledger.merkle_root source_ledger)
              | `Target_changed _ ->
                  heartbeat_flag := false ;
                  failwith "target of sync_ledger should not change" ) )

    let to_external_transition breadcrumb =
      Transition_frontier.Breadcrumb.validated_transition breadcrumb
      |> External_transition.Validation.forget_validation

    let%test "a node should be able to give a valid proof of their root" =
      heartbeat_flag := true ;
      let max_length = 4 in
      (* Generating this many breadcrumbs will ernsure the transition_frontier to be full  *)
      let num_breadcrumbs = max_length + 2 in
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind frontier =
            create_root_frontier ~logger ~pids Genesis_ledger.accounts
          in
          let%bind () =
            build_frontier_randomly frontier
              ~gen_root_breadcrumb_builder:
                (gen_linear_breadcrumbs ~logger ~pids ~trust_system
                   ~size:num_breadcrumbs
                   ~accounts_with_secret_keys:Genesis_ledger.accounts)
          in
          let seen_transition =
            Transition_frontier.(
              all_breadcrumbs frontier |> List.permute |> List.hd_exn
              |> Breadcrumb.validated_transition)
          in
          let observed_state =
            External_transition.Validated.protocol_state seen_transition
            |> Protocol_state.consensus_state
          in
          let root_with_proof =
            Option.value_exn ~message:"Could not produce an ancestor proof"
              (Sync_handler.Root.prove ~logger ~frontier observed_state)
          in
          let%bind verify =
            f_with_verifier ~f:Sync_handler.Root.verify ~logger ~pids
          in
          let%map `Root (root_transition, _), `Best_tip (best_tip_transition, _)
              =
            verify observed_state root_with_proof |> Deferred.Or_error.ok_exn
          in
          heartbeat_flag := false ;
          External_transition.(
            equal
              (With_hash.data root_transition)
              (to_external_transition (Transition_frontier.root frontier))
            && equal
                 (With_hash.data best_tip_transition)
                 (to_external_transition
                    (Transition_frontier.best_tip frontier))) )

    let%test "a node that is synced to the network should be able to provide \
              its best tip to an offline node" =
      let num_breadcrumbs_to_cause_bootstrap =
        (2 * max_length) + Consensus.Constants.delta + 1
      in
      heartbeat_flag := true ;
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind frontier =
            create_root_frontier ~logger ~pids Genesis_ledger.accounts
          in
          let root_breadcrumb = Transition_frontier.root frontier in
          let root_transition =
            Transition_frontier.Breadcrumb.validated_transition root_breadcrumb
          in
          let%bind () =
            build_frontier_randomly frontier
              ~gen_root_breadcrumb_builder:
                (gen_linear_breadcrumbs ~logger ~pids ~trust_system
                   ~size:num_breadcrumbs_to_cause_bootstrap
                   ~accounts_with_secret_keys:Genesis_ledger.accounts)
          in
          let root_consensus_state =
            External_transition.Validated.consensus_state root_transition
          in
          let peer_best_tip_with_witness =
            Option.value_exn
              (Sync_handler.Bootstrappable_best_tip.prove ~logger ~frontier
                 root_consensus_state)
          in
          let%bind verify =
            f_with_verifier ~f:Sync_handler.Bootstrappable_best_tip.verify
              ~logger ~pids
          in
          let%map verification_result =
            verify root_consensus_state peer_best_tip_with_witness
          in
          heartbeat_flag := false ;
          Result.is_ok verification_result )
  end )
*)
