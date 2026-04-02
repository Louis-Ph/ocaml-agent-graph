let merge items =
  let ordered_items =
    List.sort
      (fun left right ->
        Core_agent_name.compare left.Core_payload.agent right.Core_payload.agent)
      items
  in
  Core_payload.Batch ordered_items

