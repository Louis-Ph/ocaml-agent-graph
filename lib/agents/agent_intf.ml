type run_result = Core_payload.t * Core_payload.metrics * string list

module type S = sig
  val id : Core_agent_name.t
  val run : Runtime_services.t -> Core_context.t -> Core_payload.t -> run_result Lwt.t
end

type packed = (module S)
