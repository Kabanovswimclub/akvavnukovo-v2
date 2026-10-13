begin;

-- Reconcile only the moved lesson. Moving a completed visit into the future
-- restores its credit; moving it back into the past consumes exactly one.
create or replace function private.reconcile_moved_lesson_charge(p_lesson_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_lesson public.lessons; v_part record; v_net numeric;
begin
  select * into v_lesson from public.lessons where id=p_lesson_id;
  if not found or v_lesson.status<>'scheduled' or v_lesson.first_visit_complimentary then return; end if;
  for v_part in select distinct subscription_id from public.lesson_participants
    where lesson_id=p_lesson_id and subscription_id is not null loop
    select coalesce(sum(case when operation='lesson_charge' then quantity
                       when operation='lesson_refund' then -quantity else 0 end),0)
      into v_net from public.subscription_operations
      where lesson_id=p_lesson_id and subscription_id=v_part.subscription_id;
    if v_lesson.ends_at<=now() and v_net<1 then
      insert into public.subscription_operations
        (subscription_id,operation,quantity,lesson_id,author_user_id,comment)
      values(v_part.subscription_id,'lesson_charge',1-v_net,p_lesson_id,auth.uid(),
             'Списание после согласованного переноса прошедшего занятия');
    elsif v_lesson.ends_at>now() and v_net>0 then
      insert into public.subscription_operations
        (subscription_id,operation,quantity,lesson_id,author_user_id,comment)
      values(v_part.subscription_id,'lesson_refund',v_net,p_lesson_id,auth.uid(),
             'Возврат после согласованного переноса занятия в будущее');
    end if;
  end loop;
end $$;
revoke all on function private.reconcile_moved_lesson_charge(uuid) from public,anon,authenticated;

-- Only approved historical moves call this trigger: ordinary future-to-future
-- edits stay on their existing path.
create or replace function private.reconcile_approved_historical_move()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status='approved' and old.status='pending' and new.kind='move' then
    perform private.reconcile_moved_lesson_charge(new.applied_lesson_id);
  end if;
  return new;
end $$;
revoke all on function private.reconcile_approved_historical_move() from public,anon,authenticated;
create trigger reconcile_approved_historical_move after update of status
on public.lesson_change_requests for each row
execute function private.reconcile_approved_historical_move();

commit;
