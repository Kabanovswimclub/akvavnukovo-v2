insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('coach-photos','coach-photos',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy coach_photos_owner_insert on storage.objects for insert to authenticated
with check(bucket_id='coach-photos' and(private.is_manager() or(storage.foldername(name))[1]=private.current_instructor_id()::text));
create policy coach_photos_owner_update on storage.objects for update to authenticated
using(bucket_id='coach-photos' and(private.is_manager() or(storage.foldername(name))[1]=private.current_instructor_id()::text))
with check(bucket_id='coach-photos' and(private.is_manager() or(storage.foldername(name))[1]=private.current_instructor_id()::text));
create policy coach_photos_owner_delete on storage.objects for delete to authenticated
using(bucket_id='coach-photos' and(private.is_manager() or(storage.foldername(name))[1]=private.current_instructor_id()::text));
