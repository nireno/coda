(** This module is the core implementation of the in memory "full frontier".
 *  In this context, "full" refers to the fact that this frontier contains
 *  "fully expanded blockchain states" (i.e. [Breadcrumb]s). By comparison,
 *  the persistent frontier only contains "light blockchain states" (i.e.
 *  [External_transition]s). This module is only concerned with the core
 *  data structure of the frontier, and is further wrapped with logic to
 *  integrate the core data structure with the various other concerns of
 *  the transition frontier (e.g. extensions, persistence, etc...) in the
 *  externally available [Transition_frontier] module.
 *)

open Coda_base
open Frontier_base

include Frontier_intf.S

val create :
     logger:Logger.t
  -> root_data:Root_data.t
  -> root_ledger:Ledger.Any_ledger.witness
  -> base_hash:Frontier_hash.t
  -> consensus_local_state:Consensus.Data.Local_state.t
  -> max_length:int
  -> t

val close : t -> unit

val root_data : t -> Root_data.t

val set_hash_unsafe : t -> [`I_promise_this_is_safe of Frontier_hash.t] -> unit

val hash : t -> Frontier_hash.t

val calculate_diffs : t -> Breadcrumb.t -> Diff.Full.E.t list

val apply_diffs :
  t -> Diff.Full.E.t list -> [`New_root of Root_identifier.t option]

module For_tests : sig
  val equal : t -> t -> bool
end
