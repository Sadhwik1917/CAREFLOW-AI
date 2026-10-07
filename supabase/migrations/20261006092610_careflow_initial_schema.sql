-- ============================================================
-- CAREFLOW AI
-- Initial PostgreSQL Database Schema
-- ============================================================

-- ============================================================
-- 1. ENUM TYPES
-- ============================================================

create type public.platform_role as enum (
  'PLATFORM_ADMIN',
  'USER'
);

create type public.member_role as enum (
  'OWNER',
  'DOCTOR',
  'STAFF',
  'PATIENT'
);

create type public.member_status as enum (
  'ACTIVE',
  'INVITED',
  'SUSPENDED',
  'REMOVED'
);

create type public.clinic_status as enum (
  'ACTIVE',
  'INACTIVE',
  'SUSPENDED'
);

create type public.onboarding_status as enum (
  'NOT_STARTED',
  'IN_PROGRESS',
  'COMPLETED'
);

create type public.doctor_status as enum (
  'ACTIVE',
  'INACTIVE',
  'ON_LEAVE'
);

create type public.invitation_status as enum (
  'PENDING',
  'ACCEPTED',
  'EXPIRED',
  'CANCELLED'
);

create type public.plan_clinic_mode as enum (
  'SINGLE',
  'MULTI',
  'SINGLE_OR_MULTI'
);

create type public.ai_credit_type as enum (
  'NONE',
  'LIMITED',
  'UNLIMITED'
);

create type public.subscription_status as enum (
  'TRIAL_ACTIVE',
  'TRIAL_CANCELLED',
  'TRIAL_EXPIRED',
  'ACTIVE',
  'PAST_DUE',
  'CANCELLED',
  'EXPIRED'
);

create type public.subscription_type as enum (
  'TRIAL',
  'PAID'
);

create type public.trial_event_type as enum (
  'TRIAL_STARTED',
  'MANDATE_CREATED',
  'TRIAL_EXPIRY_REMINDER_SENT',
  'TRIAL_CANCELLED',
  'TRIAL_EXPIRED',
  'TRIAL_CONVERTED',
  'PAYMENT_SUCCESS',
  'PAYMENT_FAILED'
);

create type public.appointment_status as enum (
  'SCHEDULED',
  'CONFIRMED',
  'CHECKED_IN',
  'IN_QUEUE',
  'IN_PROGRESS',
  'COMPLETED',
  'CANCELLED',
  'NO_SHOW'
);

create type public.appointment_type as enum (
  'CONSULTATION',
  'FOLLOW_UP',
  'EMERGENCY',
  'OTHER'
);

create type public.queue_status as enum (
  'WAITING',
  'CALLED',
  'IN_CONSULTATION',
  'COMPLETED',
  'SKIPPED',
  'CANCELLED'
);

create type public.consultation_status as enum (
  'DRAFT',
  'IN_PROGRESS',
  'COMPLETED',
  'CANCELLED'
);

create type public.prescription_status as enum (
  'ACTIVE',
  'COMPLETED',
  'CANCELLED'
);

create type public.invoice_status as enum (
  'DRAFT',
  'ISSUED',
  'PARTIALLY_PAID',
  'PAID',
  'CANCELLED',
  'REFUNDED'
);

create type public.payment_status as enum (
  'PENDING',
  'SUCCESS',
  'FAILED',
  'REFUNDED',
  'CANCELLED'
);

create type public.payment_method as enum (
  'CASH',
  'CARD',
  'UPI',
  'BANK_TRANSFER',
  'ONLINE',
  'OTHER'
);

create type public.ai_interaction_status as enum (
  'REQUESTED',
  'COMPLETED',
  'FAILED',
  'BLOCKED'
);


-- ============================================================
-- 2. UPDATED_AT FUNCTION
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ============================================================
-- 3. PROFILES
-- Linked to Supabase auth.users
-- ============================================================

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,

  display_name text,
  phone text,
  avatar_url text,

  platform_role public.platform_role not null default 'USER',

  status text not null default 'ACTIVE',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- ============================================================
-- 4. CLINICS
-- ============================================================

create table public.clinics (
  id uuid primary key default gen_random_uuid(),

  owner_user_id uuid not null
    references public.profiles(id),

  name text not null,
  clinic_code text not null unique,

  phone text,
  email text,

  address text,
  city text,
  state text,
  country text not null default 'India',

  timezone text not null default 'Asia/Kolkata',
  currency text not null default 'INR',

  logo_url text,

  status public.clinic_status not null default 'ACTIVE',

  working_hours jsonb not null default '{}'::jsonb,

  onboarding_status public.onboarding_status
    not null default 'NOT_STARTED',

  onboarding_step integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (onboarding_step >= 0)
);


-- ============================================================
-- 5. CLINIC MEMBERS
-- ============================================================

create table public.clinic_members (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  user_id uuid not null
    references public.profiles(id) on delete cascade,

  role public.member_role not null,

  status public.member_status not null default 'ACTIVE',

  joined_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (clinic_id, user_id)
);


-- ============================================================
-- 6. CLINIC INVITATIONS
-- ============================================================

create table public.clinic_invitations (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  email text not null,

  role public.member_role not null,

  invited_by uuid not null
    references public.profiles(id),

  status public.invitation_status not null default 'PENDING',

  expires_at timestamptz not null,

  created_at timestamptz not null default now()
);


-- ============================================================
-- 7. DOCTOR PROFILES
-- ============================================================

create table public.doctor_profiles (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  user_id uuid not null
    references public.profiles(id) on delete cascade,

  specialization text not null,
  department text,

  qualification text,
  experience_years integer not null default 0,

  license_number text,

  consultation_fee numeric(12,2),

  bio text,

  availability jsonb not null default '{}'::jsonb,

  status public.doctor_status not null default 'ACTIVE',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (clinic_id, user_id),

  check (experience_years >= 0),
  check (consultation_fee is null or consultation_fee >= 0)
);


-- ============================================================
-- 8. PRICING PLANS
-- ============================================================

create table public.plans (
  id uuid primary key default gen_random_uuid(),

  name text not null unique,
  description text,

  clinic_mode public.plan_clinic_mode not null,

  ai_enabled boolean not null default false,
  ai_credit_type public.ai_credit_type not null default 'NONE',
  ai_credit_limit integer,

  max_clinics integer not null default 1,
  max_doctors integer,
  max_staff integer,

  features jsonb not null default '[]'::jsonb,

  price numeric(12,2) not null default 0,
  currency text not null default 'INR',

  billing_cycle text not null default 'MONTHLY',

  trial_enabled boolean not null default false,
  trial_duration_days integer,

  requires_payment_mandate boolean not null default false,

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (price >= 0),
  check (max_clinics > 0),
  check (max_doctors is null or max_doctors > 0),
  check (max_staff is null or max_staff > 0),
  check (ai_credit_limit is null or ai_credit_limit >= 0),
  check (
    (ai_credit_type = 'LIMITED' and ai_credit_limit is not null)
    or
    (ai_credit_type <> 'LIMITED')
  ),
  check (
    (trial_enabled = true and trial_duration_days is not null and trial_duration_days > 0)
    or
    (trial_enabled = false)
  )
);


-- ============================================================
-- 9. CLINIC SUBSCRIPTIONS
-- Subscription belongs to the clinic owner/customer.
-- One subscription can cover one or multiple clinics.
-- ============================================================

create table public.clinic_subscriptions (
  id uuid primary key default gen_random_uuid(),

  owner_user_id uuid not null
    references public.profiles(id),

  plan_id uuid not null
    references public.plans(id),

  status public.subscription_status not null,

  subscription_type public.subscription_type not null,

  trial_start_date timestamptz,
  trial_end_date timestamptz,
  trial_cancelled_at timestamptz,

  auto_renew boolean not null default true,

  payment_mandate_id text,
  payment_provider text,

  billing_cycle text not null default 'MONTHLY',

  amount numeric(12,2) not null default 0,
  currency text not null default 'INR',

  next_billing_date timestamptz,

  start_date timestamptz not null default now(),
  renewal_date timestamptz,

  cancelled_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (amount >= 0),

  check (
    (subscription_type = 'TRIAL'
      and trial_start_date is not null
      and trial_end_date is not null)
    or
    (subscription_type = 'PAID')
  ),

  check (
    trial_end_date is null
    or trial_start_date is null
    or trial_end_date > trial_start_date
  )
);


-- ============================================================
-- 10. SUBSCRIPTION CLINICS
-- Connects a subscription to one or multiple clinics.
-- ============================================================

create table public.subscription_clinics (
  id uuid primary key default gen_random_uuid(),

  subscription_id uuid not null
    references public.clinic_subscriptions(id) on delete cascade,

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  created_at timestamptz not null default now(),

  unique (subscription_id, clinic_id)
);


-- ============================================================
-- 11. TRIAL EVENTS
-- ============================================================

create table public.trial_events (
  id uuid primary key default gen_random_uuid(),

  subscription_id uuid not null
    references public.clinic_subscriptions(id) on delete cascade,

  clinic_id uuid
    references public.clinics(id) on delete set null,

  event_type public.trial_event_type not null,

  event_date timestamptz not null default now(),

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);


-- ============================================================
-- 12. PATIENTS
-- ============================================================

create table public.patients (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  user_id uuid
    references public.profiles(id) on delete set null,

  patient_number text not null,

  first_name text not null,
  last_name text,

  date_of_birth date,
  gender text,

  phone text,
  email text,

  address text,

  emergency_contact_name text,
  emergency_contact_phone text,

  notes text,

  status text not null default 'ACTIVE',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (clinic_id, patient_number)
);


-- ============================================================
-- 13. APPOINTMENTS
-- ============================================================

create table public.appointments (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  patient_id uuid not null
    references public.patients(id),

  doctor_profile_id uuid
    references public.doctor_profiles(id),

  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,

  appointment_type public.appointment_type
    not null default 'CONSULTATION',

  reason text,

  status public.appointment_status
    not null default 'SCHEDULED',

  notes text,

  created_by uuid
    references public.profiles(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (scheduled_end > scheduled_start)
);


-- ============================================================
-- 14. QUEUE ENTRIES
-- ============================================================

create table public.queue_entries (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  appointment_id uuid
    references public.appointments(id) on delete set null,

  patient_id uuid not null
    references public.patients(id),

  doctor_profile_id uuid
    references public.doctor_profiles(id),

  queue_date date not null default current_date,

  queue_number integer not null,

  status public.queue_status not null default 'WAITING',

  checked_in_at timestamptz,
  called_at timestamptz,
  consultation_started_at timestamptz,
  completed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (clinic_id, queue_date, queue_number),

  check (queue_number > 0)
);


-- ============================================================
-- 15. CONSULTATIONS
-- ============================================================

create table public.consultations (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  appointment_id uuid
    references public.appointments(id),

  patient_id uuid not null
    references public.patients(id),

  doctor_profile_id uuid not null
    references public.doctor_profiles(id),

  chief_complaint text,
  clinical_notes text,
  assessment text,
  follow_up_notes text,

  follow_up_date date,

  status public.consultation_status not null default 'DRAFT',

  completed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- ============================================================
-- 16. VITALS
-- ============================================================

create table public.vitals (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  patient_id uuid not null
    references public.patients(id),

  appointment_id uuid
    references public.appointments(id),

  consultation_id uuid
    references public.consultations(id),

  temperature numeric(5,2),

  blood_pressure_systolic integer,
  blood_pressure_diastolic integer,

  heart_rate integer,
  respiratory_rate integer,

  oxygen_saturation numeric(5,2),

  weight numeric(6,2),
  height numeric(6,2),

  recorded_by uuid
    references public.profiles(id),

  recorded_at timestamptz not null default now(),

  created_at timestamptz not null default now(),

  check (temperature is null or temperature >= 0),
  check (blood_pressure_systolic is null or blood_pressure_systolic >= 0),
  check (blood_pressure_diastolic is null or blood_pressure_diastolic >= 0),
  check (heart_rate is null or heart_rate >= 0),
  check (respiratory_rate is null or respiratory_rate >= 0),
  check (
    oxygen_saturation is null
    or (oxygen_saturation >= 0 and oxygen_saturation <= 100)
  ),
  check (weight is null or weight >= 0),
  check (height is null or height >= 0)
);


-- ============================================================
-- 17. PRESCRIPTIONS
-- ============================================================

create table public.prescriptions (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  patient_id uuid not null
    references public.patients(id),

  doctor_profile_id uuid not null
    references public.doctor_profiles(id),

  consultation_id uuid
    references public.consultations(id),

  prescription_date date not null default current_date,

  instructions text,

  status public.prescription_status not null default 'ACTIVE',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- ============================================================
-- 18. PRESCRIPTION ITEMS
-- ============================================================

create table public.prescription_items (
  id uuid primary key default gen_random_uuid(),

  prescription_id uuid not null
    references public.prescriptions(id) on delete cascade,

  medicine_name text not null,

  dosage text,
  frequency text,
  duration text,

  instructions text,

  created_at timestamptz not null default now()
);


-- ============================================================
-- 19. INVOICES
-- ============================================================

create table public.invoices (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  patient_id uuid not null
    references public.patients(id),

  appointment_id uuid
    references public.appointments(id),

  invoice_number text not null,

  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  tax numeric(12,2) not null default 0,

  total_amount numeric(12,2) not null default 0,
  amount_paid numeric(12,2) not null default 0,
  amount_due numeric(12,2) not null default 0,

  status public.invoice_status not null default 'DRAFT',

  issued_at timestamptz,

  created_by uuid
    references public.profiles(id),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (clinic_id, invoice_number),

  check (subtotal >= 0),
  check (discount >= 0),
  check (tax >= 0),
  check (total_amount >= 0),
  check (amount_paid >= 0),
  check (amount_due >= 0)
);


-- ============================================================
-- 20. INVOICE ITEMS
-- ============================================================

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),

  invoice_id uuid not null
    references public.invoices(id) on delete cascade,

  description text not null,

  quantity numeric(12,2) not null default 1,
  unit_price numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,

  created_at timestamptz not null default now(),

  check (quantity > 0),
  check (unit_price >= 0),
  check (total >= 0)
);


-- ============================================================
-- 21. PATIENT PAYMENTS
-- Payments made by patients to the clinic.
-- ============================================================

create table public.payments (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid not null
    references public.clinics(id) on delete cascade,

  patient_id uuid not null
    references public.patients(id),

  invoice_id uuid
    references public.invoices(id),

  amount numeric(12,2) not null,

  payment_method public.payment_method not null,

  transaction_reference text,

  status public.payment_status not null default 'PENDING',

  paid_at timestamptz,

  recorded_by uuid
    references public.profiles(id),

  created_at timestamptz not null default now(),

  check (amount > 0)
);


-- ============================================================
-- 22. PLATFORM PAYMENTS
-- Payments made by clinic owners to CAREFLOW.
-- ============================================================

create table public.platform_payments (
  id uuid primary key default gen_random_uuid(),

  subscription_id uuid
    references public.clinic_subscriptions(id) on delete set null,

  owner_user_id uuid not null
    references public.profiles(id),

  amount numeric(12,2) not null,

  currency text not null default 'INR',

  payment_method text,

  transaction_reference text,

  status public.payment_status not null default 'PENDING',

  paid_at timestamptz,

  created_at timestamptz not null default now(),

  check (amount > 0)
);


-- ============================================================
-- 23. NOTIFICATIONS
-- ============================================================

create table public.notifications (
  id uuid primary key default gen_random_uuid(),

  recipient_user_id uuid not null
    references public.profiles(id) on delete cascade,

  clinic_id uuid
    references public.clinics(id) on delete cascade,

  type text not null,

  title text not null,
  message text not null,

  related_entity_type text,
  related_entity_id uuid,

  is_read boolean not null default false,

  created_at timestamptz not null default now()
);


-- ============================================================
-- 24. AI INTERACTIONS
-- ============================================================

create table public.ai_interactions (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid
    references public.clinics(id) on delete cascade,

  user_id uuid not null
    references public.profiles(id) on delete cascade,

  feature text not null,

  related_entity_type text,
  related_entity_id uuid,

  request_metadata jsonb not null default '{}'::jsonb,
  response_metadata jsonb not null default '{}'::jsonb,

  status public.ai_interaction_status not null default 'REQUESTED',

  created_at timestamptz not null default now()
);


-- ============================================================
-- 25. AI USAGE
-- ============================================================

create table public.ai_usage (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid
    references public.clinics(id) on delete cascade,

  user_id uuid not null
    references public.profiles(id) on delete cascade,

  feature text not null,

  credits_used integer not null default 0,

  period_start timestamptz not null,
  period_end timestamptz not null,

  created_at timestamptz not null default now(),

  check (credits_used >= 0),
  check (period_end > period_start)
);


-- ============================================================
-- 26. AUDIT LOGS
-- ============================================================

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),

  clinic_id uuid
    references public.clinics(id) on delete set null,

  user_id uuid
    references public.profiles(id) on delete set null,

  action text not null,

  entity_type text not null,
  entity_id uuid,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);


-- ============================================================
-- 27. UPDATED_AT TRIGGERS
-- ============================================================

create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger set_clinics_updated_at
before update on public.clinics
for each row execute function public.set_updated_at();

create trigger set_clinic_members_updated_at
before update on public.clinic_members
for each row execute function public.set_updated_at();

create trigger set_doctor_profiles_updated_at
before update on public.doctor_profiles
for each row execute function public.set_updated_at();

create trigger set_plans_updated_at
before update on public.plans
for each row execute function public.set_updated_at();

create trigger set_clinic_subscriptions_updated_at
before update on public.clinic_subscriptions
for each row execute function public.set_updated_at();

create trigger set_patients_updated_at
before update on public.patients
for each row execute function public.set_updated_at();

create trigger set_appointments_updated_at
before update on public.appointments
for each row execute function public.set_updated_at();

create trigger set_queue_entries_updated_at
before update on public.queue_entries
for each row execute function public.set_updated_at();

create trigger set_consultations_updated_at
before update on public.consultations
for each row execute function public.set_updated_at();

create trigger set_prescriptions_updated_at
before update on public.prescriptions
for each row execute function public.set_updated_at();

create trigger set_invoices_updated_at
before update on public.invoices
for each row execute function public.set_updated_at();


-- ============================================================
-- 28. INDEXES
-- ============================================================

create index idx_careflow_clinics_owner
on public.clinics(owner_user_id);

create index idx_careflow_clinic_members_user
on public.clinic_members(user_id);

create index idx_careflow_clinic_members_clinic
on public.clinic_members(clinic_id);

create index idx_careflow_invitations_clinic
on public.clinic_invitations(clinic_id);

create index idx_careflow_invitations_email
on public.clinic_invitations(email);

create index idx_careflow_doctor_profiles_clinic
on public.doctor_profiles(clinic_id);

create index idx_careflow_doctor_profiles_user
on public.doctor_profiles(user_id);

create index idx_careflow_patients_clinic
on public.patients(clinic_id);

create index idx_careflow_patients_user
on public.patients(user_id);

create index idx_careflow_appointments_clinic
on public.appointments(clinic_id);

create index idx_careflow_appointments_patient
on public.appointments(patient_id);

create index idx_careflow_appointments_doctor
on public.appointments(doctor_profile_id);

create index idx_careflow_appointments_start
on public.appointments(scheduled_start);

create index idx_careflow_queue_clinic_date
on public.queue_entries(clinic_id, queue_date);

create index idx_careflow_consultations_patient
on public.consultations(patient_id);

create index idx_careflow_consultations_doctor
on public.consultations(doctor_profile_id);

create index idx_careflow_vitals_patient
on public.vitals(patient_id);

create index idx_careflow_prescriptions_patient
on public.prescriptions(patient_id);

create index idx_careflow_prescriptions_doctor
on public.prescriptions(doctor_profile_id);

create index idx_careflow_invoices_patient
on public.invoices(patient_id);

create index idx_careflow_payments_invoice
on public.payments(invoice_id);

create index idx_careflow_payments_patient
on public.payments(patient_id);

create index idx_careflow_notifications_recipient
on public.notifications(recipient_user_id);

create index idx_careflow_ai_interactions_user
on public.ai_interactions(user_id);

create index idx_careflow_ai_interactions_clinic
on public.ai_interactions(clinic_id);

create index idx_careflow_ai_usage_clinic_period
on public.ai_usage(clinic_id, period_start, period_end);

create index idx_careflow_audit_logs_clinic
on public.audit_logs(clinic_id);

create index idx_careflow_audit_logs_user
on public.audit_logs(user_id);

create index idx_careflow_subscriptions_owner
on public.clinic_subscriptions(owner_user_id);

create index idx_careflow_subscriptions_plan
on public.clinic_subscriptions(plan_id);

create index idx_careflow_subscription_clinics_subscription
on public.subscription_clinics(subscription_id);

create index idx_careflow_subscription_clinics_clinic
on public.subscription_clinics(clinic_id);

create index idx_careflow_trial_events_subscription
on public.trial_events(subscription_id);

create index idx_careflow_platform_payments_subscription
on public.platform_payments(subscription_id);

create index idx_careflow_platform_payments_owner
on public.platform_payments(owner_user_id);