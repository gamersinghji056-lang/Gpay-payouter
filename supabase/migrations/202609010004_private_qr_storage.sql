insert into storage.buckets (id,name,public) values ('provider-qr','provider-qr',false) on conflict (id) do update set public=false;

create policy provider_qr_staff_read on storage.objects for select to authenticated
  using (bucket_id='provider-qr' and private.current_role() in ('admin','operator'));
create policy provider_qr_owner_read on storage.objects for select to authenticated
  using (bucket_id='provider-qr' and (storage.foldername(name))[1] in (select id::text from public.providers where created_by=(select auth.uid())));
create policy provider_qr_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id='provider-qr' and private.current_role() in ('admin','operator'));
create policy provider_qr_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id='provider-qr' and (storage.foldername(name))[1] in (select id::text from public.providers where created_by=(select auth.uid())));
create policy provider_qr_staff_delete on storage.objects for delete to authenticated
  using (bucket_id='provider-qr' and private.current_role() in ('admin','operator'));
create policy provider_qr_owner_delete on storage.objects for delete to authenticated
  using (bucket_id='provider-qr' and (storage.foldername(name))[1] in (select id::text from public.providers where created_by=(select auth.uid())));
