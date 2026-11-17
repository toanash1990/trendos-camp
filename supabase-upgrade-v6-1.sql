-- ═══════════════════════════════════════════════════════════════
--  Trendos Camp Management — database upgrade for app v6.1
--  Customer documents (CR, VAT certificate, contract, PO) as PDF or photo.
--  Run ONCE in Supabase → SQL Editor → New query → paste all → Run,
--  after supabase-upgrade-v6.sql. Safe to run again. Data is not changed.
-- ═══════════════════════════════════════════════════════════════

-- 1. The private file store also accepts PDF files (up to 5 MB)
update storage.buckets
   set allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'],
       file_size_limit = 5242880
 where id = 'trendos-photos';

-- 2. People who may edit customers can add customer documents (stored under customers/…)
drop policy if exists trendos_docs_insert on storage.objects;
create policy trendos_docs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trendos-photos' and name like 'customers/%' and public.trendos_can_edit('companies'));

-- Done. Check: select id, allowed_mime_types from storage.buckets where id = 'trendos-photos';
