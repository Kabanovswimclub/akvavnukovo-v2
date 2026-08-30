drop function if exists public.get_payment_journal(uuid);
create function public.get_payment_journal(p_instructor_id uuid default null)
returns table(payment_id uuid,paid_at timestamptz,client_ids uuid[],client_names text,instructor_id uuid,instructor_name text,format text,duration_minutes integer,quantity numeric,amount numeric,comment text,operation_kind text,payment_method text)
language plpgsql security definer set search_path='' as $$
declare v_role public.app_role;v_own uuid;v_filter uuid;
begin
 select u.role,u.instructor_id into v_role,v_own from public.app_users u where u.id=auth.uid();
 if v_role is null then raise exception 'Нет доступа';end if;
 v_filter:=case when v_role='instructor' then v_own else p_instructor_id end;
 return query select p.id,p.paid_at,o.client_ids,o.client_names,p.instructor_id,coalesce(i.name,'Инструктор не указан'),s.format,s.duration_minutes,p.quantity,p.amount,p.comment,case when p.amount is not null then 'payment' when coalesce(p.comment,'') ilike '%начальн%' then 'initial' else 'correction' end,p.payment_method
 from public.payments p join public.subscriptions s on s.id=p.subscription_id left join public.instructors i on i.id=p.instructor_id
 cross join lateral(select array_agg(c.id order by c.name) client_ids,string_agg(c.name,', ' order by c.name) client_names from public.clients c where c.id=s.client_id or exists(select 1 from public.subscription_group_members gm where gm.group_id=s.group_id and gm.client_id=c.id))o
 where v_filter is null or p.instructor_id=v_filter order by p.paid_at desc;
end$$;
revoke all on function public.get_payment_journal(uuid) from public,anon;grant execute on function public.get_payment_journal(uuid) to authenticated;

create or replace function public.get_refund_liability(p_instructor_id uuid default null)
returns table(subscription_id uuid,client_ids uuid[],client_names text,format text,duration_minutes integer,balance numeric,paid_quantity numeric,refundable_quantity numeric,paid_amount numeric,liability_amount numeric,instructor_id uuid,instructor_name text)
language plpgsql stable security definer set search_path='' as $$
declare v_role public.app_role;v_own uuid;v_filter uuid;
begin
 select u.role,u.instructor_id into v_role,v_own from public.app_users u where u.id=auth.uid();
 if v_role is null then raise exception 'Нет доступа';end if;
 v_filter:=case when v_role='instructor' then v_own else p_instructor_id end;
 return query
 with monetary as(
  select p.subscription_id,p.instructor_id,sum(p.quantity) paid_qty,sum(p.amount) paid_sum
  from public.payments p where p.amount is not null and p.amount>0 and p.quantity>0 group by p.subscription_id,p.instructor_id
 ),totals as(select m.subscription_id,sum(m.paid_qty) total_qty from monetary m group by m.subscription_id),base as(
  select b.subscription_id,b.client_id,b.group_id,b.format,b.duration_minutes,b.balance,t.total_qty,least(greatest(b.balance,0),t.total_qty) refundable_qty
  from public.subscription_balances b join totals t on t.subscription_id=b.subscription_id where b.balance>0 and t.total_qty>0
 )
 select x.subscription_id,o.client_ids,o.client_names,x.format,x.duration_minutes,x.balance,m.paid_qty,x.refundable_qty,m.paid_sum,round(m.paid_sum*(x.refundable_qty/x.total_qty),2),m.instructor_id,coalesce(i.name,'Инструктор не указан')
 from base x join monetary m on m.subscription_id=x.subscription_id left join public.instructors i on i.id=m.instructor_id
 cross join lateral(select array_agg(c.id order by c.name) client_ids,string_agg(c.name,', ' order by c.name) client_names from public.clients c where c.id=x.client_id or exists(select 1 from public.subscription_group_members gm where gm.group_id=x.group_id and gm.client_id=c.id))o
 where v_filter is null or m.instructor_id=v_filter order by o.client_names,x.format,x.duration_minutes;
end$$;
revoke all on function public.get_refund_liability(uuid) from public,anon;grant execute on function public.get_refund_liability(uuid) to authenticated;
select pg_notify('pgrst','reload schema');
