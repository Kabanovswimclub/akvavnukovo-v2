-- Keep historical payments and tariff snapshots intact; hide unsupported trial durations.
do $$
declare
  v_updated integer;
begin
  update public.tariff_items
  set active = false,
      client_visible = false,
      updated_at = now()
  where code in ('trial-45', 'trial-60')
    and active = true;

  get diagnostics v_updated = row_count;
  if v_updated <> 2 then
    raise exception 'Expected to deactivate exactly two trial tariffs; found %', v_updated;
  end if;

  if not exists (
    select 1 from public.tariff_items
    where code = 'trial-30' and active = true and client_visible = true
  ) then
    raise exception 'The 30-minute trial tariff must remain available';
  end if;
end;
$$;
