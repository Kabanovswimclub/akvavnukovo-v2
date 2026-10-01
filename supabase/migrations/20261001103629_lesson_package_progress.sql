begin;

-- Optional attribution of a lesson to one paid package. Balances and charges are unchanged.
alter table public.lesson_participants
  add column package_payment_id uuid references public.payments(id) on delete set null,
  add column package_tracking_created_at timestamptz;

-- Existing participants stay NULL; only newly created rows get a tracking timestamp.
alter table public.lesson_participants
  alter column package_tracking_created_at set default now();

create index lesson_participants_package_payment_idx
  on public.lesson_participants(package_payment_id) where package_payment_id is not null;

create table private.lesson_package_tracking_config (
  singleton boolean primary key default true check (singleton),
  started_at timestamptz not null default now()
);
insert into private.lesson_package_tracking_config(singleton) values (true);
alter table private.lesson_package_tracking_config enable row level security;

-- Backfill only subscriptions with exactly one monetary purchase, no other credit,
-- and no more countable lessons than the package contains.
with single_purchase as (
  select p.subscription_id, min(p.id::text)::uuid as payment_id,
         max(p.quantity)::integer as capacity
  from public.payments p
  where p.amount > 0 and p.quantity > 0 and p.quantity = trunc(p.quantity)
  group by p.subscription_id
  having count(*) = 1
), clean_purchase as (
  select sp.*
  from single_purchase sp
  where not exists (
    select 1 from public.payments p
    where p.subscription_id = sp.subscription_id and p.id <> sp.payment_id and p.quantity > 0
  )
    and not exists (
      select 1 from public.subscription_operations o
      where o.subscription_id = sp.subscription_id and o.operation = 'correction' and o.quantity > 0
    )
), eligible as (
  select cp.subscription_id, cp.payment_id
  from clean_purchase cp
  left join public.lesson_participants lp on lp.subscription_id = cp.subscription_id
  left join public.lessons l on l.id = lp.lesson_id
  group by cp.subscription_id, cp.payment_id, cp.capacity
  having count(*) filter (where l.id is not null and (l.status <> 'cancelled' or l.charged_on_cancel))
         <= cp.capacity
)
update public.lesson_participants lp
set package_payment_id = e.payment_id
from eligible e, public.lessons l
where lp.subscription_id = e.subscription_id
  and l.id = lp.lesson_id
  and (l.status <> 'cancelled' or l.charged_on_cancel);

create or replace function private.assign_lesson_packages(p_subscription_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_started_at timestamptz;
  v_pending record;
  v_payment_id uuid;
begin
  if p_subscription_id is null then return; end if;
  select c.started_at into v_started_at
  from private.lesson_package_tracking_config c where c.singleton;
  perform 1 from public.subscriptions s where s.id = p_subscription_id for update;

  for v_pending in
    select lp.lesson_id, lp.client_id
    from public.lesson_participants lp
    join public.lessons l on l.id = lp.lesson_id
    where lp.subscription_id = p_subscription_id
      and lp.package_payment_id is null
      and lp.package_tracking_created_at >= v_started_at
      and (l.status <> 'cancelled' or l.charged_on_cancel)
    order by l.starts_at, lp.lesson_id, lp.client_id
  loop
    select p.id into v_payment_id
    from public.payments p
    where p.subscription_id = p_subscription_id
      and p.amount > 0 and p.quantity > 0 and p.quantity = trunc(p.quantity)
      and (p.paid_at >= v_started_at or exists (
        select 1 from public.lesson_participants existing
        where existing.package_payment_id = p.id
      ))
      and (select count(*) from public.lesson_participants assigned
           where assigned.package_payment_id = p.id) < p.quantity
    order by p.paid_at, p.id
    limit 1;

    exit when v_payment_id is null;
    update public.lesson_participants lp
    set package_payment_id = v_payment_id
    where lp.lesson_id = v_pending.lesson_id and lp.client_id = v_pending.client_id;
  end loop;
end;
$$;

create or replace function private.track_participant_package()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.assign_lesson_packages(new.subscription_id);
  return new;
end;
$$;
create trigger track_participant_package
  after insert on public.lesson_participants
  for each row execute function private.track_participant_package();

create or replace function private.track_payment_package()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.amount > 0 and new.quantity > 0 then
    perform private.assign_lesson_packages(new.subscription_id);
  end if;
  return new;
end;
$$;
create trigger track_payment_package
  after insert on public.payments
  for each row execute function private.track_payment_package();

create or replace function private.track_lesson_package_status()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_subscription record;
begin
  if new.status = 'cancelled' and not new.charged_on_cancel then
    update public.lesson_participants lp
    set package_payment_id = null
    where lp.lesson_id = new.id and lp.package_payment_id is not null;
  end if;
  for v_subscription in
    select distinct lp.subscription_id
    from public.lesson_participants lp
    where lp.lesson_id = new.id and lp.subscription_id is not null
  loop
    perform private.assign_lesson_packages(v_subscription.subscription_id);
  end loop;
  return new;
end;
$$;
create trigger track_lesson_package_status
  after update of status, charged_on_cancel on public.lessons
  for each row execute function private.track_lesson_package_status();

revoke all on function private.assign_lesson_packages(uuid) from public, anon, authenticated;
revoke all on function private.track_participant_package() from public, anon, authenticated;
revoke all on function private.track_payment_package() from public, anon, authenticated;
revoke all on function private.track_lesson_package_status() from public, anon, authenticated;

-- Rank all participants in a shared package before filtering to the requested client.
create or replace function public.get_client_lesson_package_progress(p_client_id uuid)
returns table(lesson_id uuid, lesson_number integer, total integer)
language sql stable security invoker set search_path = '' as $$
  with numbered as (
    select lp.lesson_id, lp.client_id,
           row_number() over (
             partition by p.id order by l.starts_at, l.id, lp.client_id
           )::integer as lesson_number,
           p.quantity::integer as total
    from public.lesson_participants lp
    join public.payments p on p.id = lp.package_payment_id
      and p.subscription_id = lp.subscription_id
    join public.lessons l on l.id = lp.lesson_id
    where l.status <> 'cancelled' or l.charged_on_cancel
  )
  select n.lesson_id, n.lesson_number, n.total
  from numbered n
  where n.client_id = p_client_id and public.has_access();
$$;
revoke all on function public.get_client_lesson_package_progress(uuid) from public, anon;
grant execute on function public.get_client_lesson_package_progress(uuid) to authenticated;
select pg_notify('pgrst','reload schema');

commit;
