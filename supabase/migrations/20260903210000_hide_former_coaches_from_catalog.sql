-- Catalogue visibility only: preserve staff status, access, lessons and payments.
alter table public.coach_public_cards
 add column hidden_from_catalog boolean not null default false;

update public.coach_public_cards
set hidden_from_catalog=true
where instructor_id in (
 'b20c6202-ec76-4177-ab5a-9d72cefef6cd'::uuid, -- Кабанов Александр
 'd0bfceea-a635-689f-887a-b1145301f58e'::uuid  -- Сухорукова Алёна
);

create or replace function public.get_parent_coach_catalog(p_client_id uuid default null)
returns table(instructor_id uuid,name text,card jsonb,is_mine boolean)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or private.current_guardian_id() is null then raise exception 'Нужен вход родителя';end if;
 if p_client_id is not null and not coalesce(private.guardian_can_access_client(p_client_id),false) then raise exception 'Нет доступа к ребёнку';end if;
 return query select i.id,i.name,c.published,exists(select 1 from public.client_instructors ci where ci.instructor_id=i.id and ci.client_id=p_client_id)
 from public.instructors i join public.coach_public_cards c on c.instructor_id=i.id
 where i.status='active' and not c.hidden_from_catalog order by i.name;
end$$;
select pg_notify('pgrst','reload schema');
