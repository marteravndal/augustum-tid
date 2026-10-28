insert into public.report_recipients(organization_id,email,recipient_type)
select id,'post@augustum.no','admin'
from public.organizations
where name='Augustum AS'
on conflict (organization_id,email) do update set recipient_type='admin';
