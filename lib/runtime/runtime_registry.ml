module Key = struct
  type t = Core_agent_name.t

  let equal = Core_agent_name.equal
  let hash = Core_agent_name.hash
end

module Table = Hashtbl.Make (Key)

type t = Agent_intf.packed Table.t

let create capacity = Table.create capacity

let register registry ((module Agent) as packed : Agent_intf.packed) =
  Table.replace registry Agent.id packed

let find registry agent = Table.find_opt registry agent

