-- ===== MIGRATION 0014: pg_cron ===========================================================
-- Jadwal dalam UTC. Frekuensi/jam adalah parameter operasional [P]; ubah dengan cron.alter_job().
-- Setiap job idempoten (aman bila dijalankan ulang/ganda) dan menulis heartbeat ke job_runs.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('vasta_sla_check',               '* * * * *',  $j$select app.run_job('sla_check')$j$);
    perform cron.schedule('vasta_expire_customer_actions', '*/5 * * * *', $j$select app.run_job('expire_customer_actions')$j$);
    perform cron.schedule('vasta_pm_generate',             '0 17 * * *', $j$select app.run_job('pm_generate')$j$);            -- 00:00 WIB
    perform cron.schedule('vasta_pm_missed',               '30 17 * * *', $j$select app.run_job('pm_missed')$j$);
    perform cron.schedule('vasta_parts_variance_finalize', '15 * * * *', $j$select app.run_job('parts_variance_finalize')$j$);
    perform cron.schedule('vasta_retention_purge',         '0 19 * * *', $j$select app.run_job('retention_purge')$j$);
  else
    raise notice 'pg_cron tidak aktif: jadwalkan app.run_job(<nama>) lewat scheduler eksternal (Edge Function/cron Next.js).';
  end if;
end $$;
