-- Existing records stay private. A leader must explicitly share each new version/activity.
alter table public.sick_followup_plans add column employee_shared_at timestamptz;
alter table public.sick_followup_activities add column employee_shared_at timestamptz;
comment on column public.sick_followup_plans.employee_shared_at is 'Explicit sharing to the case employee, independent of NAV/medical practitioner sharing.';
comment on column public.sick_followup_activities.employee_shared_at is 'Only explicitly shared activities are exposed by the employee-mobile API.';
create index sick_followup_plans_employee_shared_idx on public.sick_followup_plans(organization_id,case_id) where employee_shared_at is not null;
create index sick_followup_activities_employee_shared_idx on public.sick_followup_activities(organization_id,case_id) where employee_shared_at is not null;
-- RLS and the existing lack of anon/authenticated table grants are deliberately retained.
