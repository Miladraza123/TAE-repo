-- anon has no legitimate use for triggering a cost recompute.
revoke execute on function recompute_all_item_costs(date) from anon;
revoke execute on function recompute_item_cost(uuid, boolean) from anon;
