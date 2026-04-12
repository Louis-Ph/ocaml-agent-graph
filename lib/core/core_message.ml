type role =
  | System
  | User
  | Assistant
  | Agent of Core_agent_name.t
  | Speaker of string

type t = {
  role : role;
  content : string;
}

let role_to_string = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Agent agent -> Core_agent_name.to_string agent
  | Speaker speaker -> speaker
