-- ============================================================
-- CAREFLOW AI — RLS & SECURITY MIGRATION
-- Migration: 20261007074632_careflow_rls_security.sql
-- Apply only after 20261006092610_careflow_initial_schema.sql.
--
-- Security model:
-- * Clinic creation + initial OWNER membership happen atomically through
--   private.create_clinic_with_owner().
-- * Clinic data is tenant-scoped.
-- * Normal clients cannot write billing-provider records, AI logs/usage,
--   audit logs, invitations, or trial events directly.
-- * Sensitive writes should go through authenticated RPCs / trusted Edge
--   Functions with explicit authorization.
-- ============================================================

BEGIN;

-- 1. Private helper functions. Keep private schema out of exposed API schemas.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE OR REPLACE FUNCTION private.is_platform_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.platform_role = 'PLATFORM_ADMIN'::public.platform_role
      AND p.status = 'ACTIVE'
  );
$$;


CREATE OR REPLACE FUNCTION private.protect_clinic_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id
     AND (SELECT auth.uid()) IS NOT NULL
     AND NOT private.is_platform_admin()
  THEN
    RAISE EXCEPTION
      'Only a platform administrator can change clinic ownership';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.protect_clinic_owner() FROM PUBLIC;

DROP TRIGGER IF EXISTS protect_clinic_owner ON public.clinics;

CREATE TRIGGER protect_clinic_owner
BEFORE UPDATE OF owner_user_id ON public.clinics
FOR EACH ROW
EXECUTE FUNCTION private.protect_clinic_owner();


CREATE OR REPLACE FUNCTION private.is_clinic_member(p_clinic_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.clinic_members cm
    WHERE cm.clinic_id = p_clinic_id
      AND cm.user_id = (SELECT auth.uid())
      AND cm.status = 'ACTIVE'::public.member_status
  );
$$;

CREATE OR REPLACE FUNCTION private.has_clinic_role(
  p_clinic_id uuid,
  p_roles public.member_role[]
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.clinic_members cm
    WHERE cm.clinic_id = p_clinic_id
      AND cm.user_id = (SELECT auth.uid())
      AND cm.status = 'ACTIVE'::public.member_status
      AND cm.role = ANY(p_roles)
  );
$$;

CREATE OR REPLACE FUNCTION private.is_patient_for_clinic(
  p_clinic_id uuid,
  p_patient_id uuid
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.patients p
    WHERE p.id = p_patient_id
      AND p.clinic_id = p_clinic_id
      AND p.user_id = (SELECT auth.uid())
  );
$$;


CREATE OR REPLACE FUNCTION private.prevent_clinic_reassignment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.clinic_id IS DISTINCT FROM OLD.clinic_id THEN
    RAISE EXCEPTION
      'Clinic assignment cannot be changed after record creation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.prevent_clinic_reassignment() FROM PUBLIC;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'ai_interactions',
    'ai_usage',
    'appointments',
    'clinic_invitations',
    'clinic_members',
    'consultations',
    'doctor_profiles',
    'invoices',
    'notifications',
    'patients',
    'payments',
    'prescriptions',
    'queue_entries',
    'subscription_clinics',
    'vitals'
  ]
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS prevent_clinic_reassignment ON public.%I',
      table_name
    );

    EXECUTE format(
      'CREATE TRIGGER prevent_clinic_reassignment
       BEFORE UPDATE OF clinic_id ON public.%I
       FOR EACH ROW
       EXECUTE FUNCTION private.prevent_clinic_reassignment()',
      table_name
    );
  END LOOP;
END;
$$;


REVOKE ALL ON FUNCTION private.is_platform_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_clinic_member(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.has_clinic_role(uuid, public.member_role[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.is_patient_for_clinic(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.is_platform_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_clinic_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_clinic_role(uuid, public.member_role[]) TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_patient_for_clinic(uuid, uuid) TO authenticated;

-- 2. Protect the platform role from user self-promotion.
CREATE OR REPLACE FUNCTION private.protect_platform_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF (
    NEW.platform_role IS DISTINCT FROM OLD.platform_role
    OR NEW.status IS DISTINCT FROM OLD.status
  )
  AND (SELECT auth.uid()) IS NOT NULL
  AND NOT private.is_platform_admin()
  THEN
    RAISE EXCEPTION
      'Only a platform administrator can change platform role or profile status';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_profile_platform_role ON public.profiles;
CREATE TRIGGER protect_profile_platform_role
BEFORE UPDATE ON public.profiles
FOR EACH ROW EXECUTE FUNCTION private.protect_platform_role();

-- 3. Create a profile for each new Supabase Auth user. The platform role is
-- always USER; metadata supplied by a browser cannot grant admin privileges.
CREATE OR REPLACE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name, platform_role)
  VALUES (
    NEW.id,
    NULLIF(NEW.raw_user_meta_data ->> 'display_name', ''),
    'USER'::public.platform_role
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION private.handle_new_user();

-- 4. Atomic clinic creation and initial OWNER membership.
-- The caller cannot choose another owner or self-assign a different role.
CREATE OR REPLACE FUNCTION private.create_clinic_with_owner(
  p_name text,
  p_clinic_code text,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_country text DEFAULT 'India',
  p_timezone text DEFAULT 'Asia/Kolkata',
  p_currency text DEFAULT 'INR'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_clinic_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_user_id AND p.status = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'Active profile required';
  END IF;
  IF NULLIF(trim(p_name), '') IS NULL
     OR NULLIF(trim(p_clinic_code), '') IS NULL THEN
    RAISE EXCEPTION 'Clinic name and clinic code are required';
  END IF;

  INSERT INTO public.clinics (
    owner_user_id, name, clinic_code, phone, email, address, city, state,
    country, timezone, currency
  )
  VALUES (
    v_user_id, trim(p_name), trim(p_clinic_code), p_phone, p_email, p_address,
    p_city, p_state, p_country, p_timezone, p_currency
  )
  RETURNING id INTO v_clinic_id;

  INSERT INTO public.clinic_members (
    clinic_id, user_id, role, status, joined_at
  )
  VALUES (
    v_clinic_id, v_user_id, 'OWNER'::public.member_role,
    'ACTIVE'::public.member_status, now()
  );

  RETURN v_clinic_id;
END;
$$;

REVOKE ALL ON FUNCTION private.create_clinic_with_owner(
  text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.create_clinic_with_owner(
  text, text, text, text, text, text, text, text, text, text
) TO authenticated;

-- Expose a narrow public RPC wrapper because Supabase RPC cannot call private
-- schema functions unless that schema is exposed. The wrapper has no role input.
CREATE OR REPLACE FUNCTION public.create_clinic_with_owner(
  p_name text,
  p_clinic_code text,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_country text DEFAULT 'India',
  p_timezone text DEFAULT 'Asia/Kolkata',
  p_currency text DEFAULT 'INR'
)
RETURNS uuid
LANGUAGE sql SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.create_clinic_with_owner(
    p_name, p_clinic_code, p_phone, p_email, p_address, p_city, p_state,
    p_country, p_timezone, p_currency
  );
$$;
REVOKE ALL ON FUNCTION public.create_clinic_with_owner(
  text, text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_clinic_with_owner(
  text, text, text, text, text, text, text, text, text, text
) TO authenticated;

-- 5. Enable RLS on all 24 public application tables.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename IN (
        'profiles','clinics','clinic_members','clinic_invitations',
        'doctor_profiles','plans','clinic_subscriptions','subscription_clinics',
        'trial_events','patients','appointments','queue_entries','consultations',
        'vitals','prescriptions','prescription_items','invoices','invoice_items',
        'payments','platform_payments','notifications','ai_interactions',
        'ai_usage','audit_logs'
      )
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tablename);
  END LOOP;
END;
$$;

-- 6. Policies below are created once by this migration. Do not drop unrelated
-- policies across the public schema; a failed transaction rolls back atomically.

-- PROFILES: users read/update their own profile; admins can read/update all.
CREATE POLICY profiles_select ON public.profiles
FOR SELECT TO authenticated
USING (id = (SELECT auth.uid()) OR private.is_platform_admin());

CREATE POLICY profiles_update ON public.profiles
FOR UPDATE TO authenticated
USING (id = (SELECT auth.uid()) OR private.is_platform_admin())
WITH CHECK (id = (SELECT auth.uid()) OR private.is_platform_admin());

-- CLINICS: member visibility; owner updates. Creation must use atomic RPC.
CREATE POLICY clinics_select ON public.clinics
FOR SELECT TO authenticated
USING (private.is_clinic_member(id) OR owner_user_id = (SELECT auth.uid())
       OR private.is_platform_admin());

CREATE POLICY clinics_update ON public.clinics
FOR UPDATE TO authenticated
USING (private.has_clinic_role(id, ARRAY['OWNER']::public.member_role[])
       OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(id, ARRAY['OWNER']::public.member_role[])
            OR private.is_platform_admin());

CREATE POLICY clinics_admin_delete ON public.clinics
FOR DELETE TO authenticated
USING (private.is_platform_admin());

-- CLINIC MEMBERS: members can view their clinic roster; only owner/admin can
-- manage membership. Initial OWNER membership is inserted only by the RPC.
CREATE POLICY clinic_members_select ON public.clinic_members
FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR private.is_clinic_member(clinic_id)
       OR private.is_platform_admin());

CREATE POLICY clinic_members_insert ON public.clinic_members
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
            OR private.is_platform_admin());

CREATE POLICY clinic_members_update ON public.clinic_members
FOR UPDATE TO authenticated
USING (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
       OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
            OR private.is_platform_admin());

CREATE POLICY clinic_members_delete ON public.clinic_members
FOR DELETE TO authenticated
USING (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
       OR private.is_platform_admin());

-- CLINIC INVITATIONS: direct reads/writes are withheld; use a trusted invitation
-- Edge Function/RPC that verifies owner role, email and expiry.
CREATE POLICY clinic_invitations_owner_read ON public.clinic_invitations
FOR SELECT TO authenticated
USING (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
       OR private.is_platform_admin());

-- DOCTOR PROFILES: clinic members may view doctors; owner/admin manage records.
CREATE POLICY doctor_profiles_select ON public.doctor_profiles
FOR SELECT TO authenticated
USING (private.is_clinic_member(clinic_id) OR private.is_platform_admin());

CREATE POLICY doctor_profiles_insert ON public.doctor_profiles
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
            OR private.is_platform_admin());

CREATE POLICY doctor_profiles_update ON public.doctor_profiles
FOR UPDATE TO authenticated
USING (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
       OR (user_id = (SELECT auth.uid()) AND private.has_clinic_role(
         clinic_id, ARRAY['DOCTOR']::public.member_role[]))
       OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
            OR (user_id = (SELECT auth.uid()) AND private.has_clinic_role(
              clinic_id, ARRAY['DOCTOR']::public.member_role[]))
            OR private.is_platform_admin());

CREATE POLICY doctor_profiles_delete ON public.doctor_profiles
FOR DELETE TO authenticated
USING (private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
       OR private.is_platform_admin());

-- PLANS: authenticated users can view active plans; admins manage all plans.
CREATE POLICY plans_select ON public.plans
FOR SELECT TO authenticated
USING (is_active = true OR private.is_platform_admin());

CREATE POLICY plans_admin_insert ON public.plans
FOR INSERT TO authenticated WITH CHECK (private.is_platform_admin());
CREATE POLICY plans_admin_update ON public.plans
FOR UPDATE TO authenticated
USING (private.is_platform_admin()) WITH CHECK (private.is_platform_admin());
CREATE POLICY plans_admin_delete ON public.plans
FOR DELETE TO authenticated USING (private.is_platform_admin());

-- CLINIC SUBSCRIPTIONS: owner can read own subscription; writes are backend-only.
CREATE POLICY clinic_subscriptions_select ON public.clinic_subscriptions
FOR SELECT TO authenticated
USING (owner_user_id = (SELECT auth.uid()) OR private.is_platform_admin());

-- SUBSCRIPTION_CLINICS: owner can see linked clinics for their subscription.
CREATE POLICY subscription_clinics_select ON public.subscription_clinics
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.clinic_subscriptions cs
    WHERE cs.id = subscription_id
      AND (cs.owner_user_id = (SELECT auth.uid()) OR private.is_platform_admin())
  )
);

-- TRIAL EVENTS: owner can read events belonging to their subscription.
CREATE POLICY trial_events_select ON public.trial_events
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.clinic_subscriptions cs
    WHERE cs.id = subscription_id
      AND (cs.owner_user_id = (SELECT auth.uid()) OR private.is_platform_admin())
  )
);

-- PATIENTS: care team reads; owner/staff create/update; patient reads their own row.
CREATE POLICY patients_select ON public.patients
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR private.has_clinic_role(
    clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
  )
  OR private.is_platform_admin()
);

CREATE POLICY patients_insert ON public.patients
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY patients_update ON public.patients
FOR UPDATE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY patients_delete ON public.patients
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- APPOINTMENTS: owner/staff schedule; doctors update only their assigned appointments;
-- patients may read only their own appointments.
CREATE POLICY appointments_select ON public.appointments
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY appointments_insert ON public.appointments
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY appointments_update ON public.appointments
FOR UPDATE TO authenticated
USING (
  private.has_clinic_role(clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
  OR (
    doctor_profile_id IN (
      SELECT dp.id FROM public.doctor_profiles dp
      WHERE dp.clinic_id = appointments.clinic_id
        AND dp.user_id = (SELECT auth.uid())
    )
    AND private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
  )
  OR private.is_platform_admin()
)
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
  OR (
    doctor_profile_id IN (
      SELECT dp.id FROM public.doctor_profiles dp
      WHERE dp.clinic_id = appointments.clinic_id
        AND dp.user_id = (SELECT auth.uid())
    )
    AND private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
  )
  OR private.is_platform_admin()
);

CREATE POLICY appointments_delete ON public.appointments
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- QUEUE ENTRIES: owner/staff manage; assigned doctor can read/update own queue.
CREATE POLICY queue_entries_select ON public.queue_entries
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
  )
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = queue_entries.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = queue_entries.clinic_id
    )
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY queue_entries_insert ON public.queue_entries
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY queue_entries_update ON public.queue_entries
FOR UPDATE TO authenticated
USING (
  private.has_clinic_role(clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = queue_entries.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = queue_entries.clinic_id
    )
  )
  OR private.is_platform_admin()
)
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = queue_entries.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = queue_entries.clinic_id
    )
  )
  OR private.is_platform_admin()
);

CREATE POLICY queue_entries_delete ON public.queue_entries
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- CONSULTATIONS: care team can read; owner/assigned doctor can create/update.
CREATE POLICY consultations_select ON public.consultations
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY consultations_insert ON public.consultations
FOR INSERT TO authenticated
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = consultations.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = consultations.clinic_id
    )
  )
  OR private.is_platform_admin()
);

CREATE POLICY consultations_update ON public.consultations
FOR UPDATE TO authenticated
USING (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = consultations.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = consultations.clinic_id
    )
  )
  OR private.is_platform_admin()
)
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = consultations.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = consultations.clinic_id
    )
  )
  OR private.is_platform_admin()
);

CREATE POLICY consultations_delete ON public.consultations
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- VITALS: care team reads; owner/staff record; assigned doctors may record/update.
CREATE POLICY vitals_select ON public.vitals
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY vitals_insert ON public.vitals
FOR INSERT TO authenticated
WITH CHECK (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
  )
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND (recorded_by IS NULL OR recorded_by = (SELECT auth.uid()))
  )
  OR private.is_platform_admin()
);

CREATE POLICY vitals_update ON public.vitals
FOR UPDATE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY vitals_delete ON public.vitals
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- PRESCRIPTIONS: care team reads; owner/assigned doctor creates and updates.
CREATE POLICY prescriptions_select ON public.prescriptions
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY prescriptions_insert ON public.prescriptions
FOR INSERT TO authenticated
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = prescriptions.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = prescriptions.clinic_id
    )
  )
  OR private.is_platform_admin()
);

CREATE POLICY prescriptions_update ON public.prescriptions
FOR UPDATE TO authenticated
USING (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = prescriptions.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = prescriptions.clinic_id
    )
  )
  OR private.is_platform_admin()
)
WITH CHECK (
  private.has_clinic_role(clinic_id, ARRAY['OWNER']::public.member_role[])
  OR (
    private.has_clinic_role(clinic_id, ARRAY['DOCTOR']::public.member_role[])
    AND EXISTS (
      SELECT 1 FROM public.doctor_profiles dp
      WHERE dp.id = prescriptions.doctor_profile_id
        AND dp.user_id = (SELECT auth.uid())
        AND dp.clinic_id = prescriptions.clinic_id
    )
  )
  OR private.is_platform_admin()
);

CREATE POLICY prescriptions_delete ON public.prescriptions
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- PRESCRIPTION ITEMS: inherit authorization through parent prescription.
CREATE POLICY prescription_items_select ON public.prescription_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.prescriptions p
    WHERE p.id = prescription_id
      AND (
        private.has_clinic_role(
          p.clinic_id, ARRAY['OWNER','DOCTOR','STAFF']::public.member_role[]
        )
        OR private.is_patient_for_clinic(p.clinic_id, p.patient_id)
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY prescription_items_insert ON public.prescription_items
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.prescriptions p
    WHERE p.id = prescription_id
      AND (
        private.has_clinic_role(p.clinic_id, ARRAY['OWNER']::public.member_role[])
        OR (
          private.has_clinic_role(p.clinic_id, ARRAY['DOCTOR']::public.member_role[])
          AND EXISTS (
            SELECT 1 FROM public.doctor_profiles dp
            WHERE dp.id = p.doctor_profile_id
              AND dp.user_id = (SELECT auth.uid())
              AND dp.clinic_id = p.clinic_id
          )
        )
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY prescription_items_update ON public.prescription_items
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.prescriptions p
    WHERE p.id = prescription_id
      AND (
        private.has_clinic_role(p.clinic_id, ARRAY['OWNER']::public.member_role[])
        OR (
          private.has_clinic_role(p.clinic_id, ARRAY['DOCTOR']::public.member_role[])
          AND EXISTS (
            SELECT 1 FROM public.doctor_profiles dp
            WHERE dp.id = p.doctor_profile_id
              AND dp.user_id = (SELECT auth.uid())
              AND dp.clinic_id = p.clinic_id
          )
        )
        OR private.is_platform_admin()
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.prescriptions p
    WHERE p.id = prescription_id
      AND (
        private.has_clinic_role(p.clinic_id, ARRAY['OWNER']::public.member_role[])
        OR (
          private.has_clinic_role(p.clinic_id, ARRAY['DOCTOR']::public.member_role[])
          AND EXISTS (
            SELECT 1 FROM public.doctor_profiles dp
            WHERE dp.id = p.doctor_profile_id
              AND dp.user_id = (SELECT auth.uid())
              AND dp.clinic_id = p.clinic_id
          )
        )
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY prescription_items_delete ON public.prescription_items
FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.prescriptions p
    WHERE p.id = prescription_id
      AND (
        private.has_clinic_role(p.clinic_id, ARRAY['OWNER']::public.member_role[])
        OR private.is_platform_admin()
      )
  )
);

-- INVOICES: owner/staff manage; patients read their own.
CREATE POLICY invoices_select ON public.invoices
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY invoices_insert ON public.invoices
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY invoices_update ON public.invoices
FOR UPDATE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY invoices_delete ON public.invoices
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- INVOICE ITEMS: access inherits from the parent invoice.
CREATE POLICY invoice_items_select ON public.invoice_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.invoices i
    WHERE i.id = invoice_id
      AND (
        private.has_clinic_role(i.clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
        OR private.is_patient_for_clinic(i.clinic_id, i.patient_id)
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY invoice_items_insert ON public.invoice_items
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.invoices i
    WHERE i.id = invoice_id
      AND (
        private.has_clinic_role(i.clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY invoice_items_update ON public.invoice_items
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.invoices i
    WHERE i.id = invoice_id
      AND (
        private.has_clinic_role(i.clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
        OR private.is_platform_admin()
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.invoices i
    WHERE i.id = invoice_id
      AND (
        private.has_clinic_role(i.clinic_id, ARRAY['OWNER','STAFF']::public.member_role[])
        OR private.is_platform_admin()
      )
  )
);

CREATE POLICY invoice_items_delete ON public.invoice_items
FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.invoices i
    WHERE i.id = invoice_id
      AND (
        private.has_clinic_role(i.clinic_id, ARRAY['OWNER']::public.member_role[])
        OR private.is_platform_admin()
      )
  )
);

-- PATIENT PAYMENTS: owner/staff manage; patient can read own payments.
CREATE POLICY payments_select ON public.payments
FOR SELECT TO authenticated
USING (
  private.has_clinic_role(
    clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
  )
  OR private.is_patient_for_clinic(clinic_id, patient_id)
  OR private.is_platform_admin()
);

CREATE POLICY payments_insert ON public.payments
FOR INSERT TO authenticated
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY payments_update ON public.payments
FOR UPDATE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin())
WITH CHECK (private.has_clinic_role(
  clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
) OR private.is_platform_admin());

CREATE POLICY payments_delete ON public.payments
FOR DELETE TO authenticated
USING (private.has_clinic_role(
  clinic_id, ARRAY['OWNER']::public.member_role[]
) OR private.is_platform_admin());

-- PLATFORM PAYMENTS: billing-provider writes must use trusted backend/service role.
-- Current schema has no owner_user_id on platform_payments; ownership is resolved
-- through subscription_id. Orphaned rows (NULL subscription_id) are admin-only.
CREATE POLICY platform_payments_select ON public.platform_payments
FOR SELECT TO authenticated
USING (
  private.is_platform_admin()
  OR EXISTS (
    SELECT 1 FROM public.clinic_subscriptions cs
    WHERE cs.id = platform_payments.subscription_id
      AND cs.owner_user_id = (SELECT auth.uid())
  )
);

-- NOTIFICATIONS: recipient reads/updates own read state; clinic owner/staff can
-- create notifications only for members of their own clinic.
CREATE POLICY notifications_select ON public.notifications
FOR SELECT TO authenticated
USING (
  recipient_user_id = (SELECT auth.uid())
  OR private.is_platform_admin()
);

CREATE POLICY notifications_update_own ON public.notifications
FOR UPDATE TO authenticated
USING (recipient_user_id = (SELECT auth.uid()) OR private.is_platform_admin())
WITH CHECK (recipient_user_id = (SELECT auth.uid()) OR private.is_platform_admin());

CREATE POLICY notifications_insert ON public.notifications
FOR INSERT TO authenticated
WITH CHECK (
  private.is_platform_admin()
  OR (
    clinic_id IS NOT NULL
    AND private.has_clinic_role(
      clinic_id, ARRAY['OWNER','STAFF']::public.member_role[]
    )
    AND EXISTS (
      SELECT 1 FROM public.clinic_members cm
      WHERE cm.clinic_id = notifications.clinic_id
        AND cm.user_id = notifications.recipient_user_id
        AND cm.status = 'ACTIVE'::public.member_status
    )
  )
);

-- AI INTERACTIONS: read own or clinic owner/admin; all writes via trusted backend.
CREATE POLICY ai_interactions_select ON public.ai_interactions
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR private.is_platform_admin()
  OR (clinic_id IS NOT NULL AND private.has_clinic_role(
    clinic_id, ARRAY['OWNER']::public.member_role[]
  ))
);

-- AI USAGE: user sees own usage; owner sees usage for their clinic; writes backend-only.
CREATE POLICY ai_usage_select ON public.ai_usage
FOR SELECT TO authenticated
USING (
  user_id = (SELECT auth.uid())
  OR private.is_platform_admin()
  OR (clinic_id IS NOT NULL AND private.has_clinic_role(
    clinic_id, ARRAY['OWNER']::public.member_role[]
  ))
);

-- AUDIT LOGS: append/read via trusted backend; clients cannot directly mutate logs.
CREATE POLICY audit_logs_select ON public.audit_logs
FOR SELECT TO authenticated
USING (
  private.is_platform_admin()
  OR (clinic_id IS NOT NULL AND private.has_clinic_role(
    clinic_id, ARRAY['OWNER']::public.member_role[]
  ))
);


-- ============================================================
-- CROSS-CLINIC RELATIONSHIP VALIDATION
-- Prevent records from linking entities across clinics.
-- ============================================================

CREATE OR REPLACE FUNCTION private.validate_clinic_relationships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_TABLE_NAME = 'appointments' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id
        AND p.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Appointment patient must belong to the same clinic';
    END IF;

    -- A newly booked appointment may not have a doctor assigned yet.
    IF NEW.doctor_profile_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.doctor_profiles d
      WHERE d.id = NEW.doctor_profile_id
        AND d.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Appointment doctor must belong to the same clinic';
    END IF;

  ELSIF TG_TABLE_NAME = 'queue_entries' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Queue entry patient must belong to the same clinic';
    END IF;

    IF NEW.doctor_profile_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.doctor_profiles d
      WHERE d.id = NEW.doctor_profile_id AND d.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Queue entry doctor must belong to the same clinic';
    END IF;

    -- queue_entries.appointment_id and doctor_profile_id are nullable in the schema.
    IF NEW.appointment_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.appointments a
      WHERE a.id = NEW.appointment_id
        AND a.clinic_id = NEW.clinic_id
        AND a.patient_id = NEW.patient_id
        AND (
          NEW.doctor_profile_id IS NULL
          OR a.doctor_profile_id = NEW.doctor_profile_id
        )
    ) THEN
      RAISE EXCEPTION 'Queue entry appointment must match its patient, clinic and assigned doctor';
    END IF;

  ELSIF TG_TABLE_NAME = 'consultations' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) OR NOT EXISTS (
      SELECT 1 FROM public.doctor_profiles d
      WHERE d.id = NEW.doctor_profile_id AND d.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Consultation patient and doctor must belong to the same clinic';
    END IF;

    -- A consultation can be created without an appointment.
    IF NEW.appointment_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.appointments a
      WHERE a.id = NEW.appointment_id
        AND a.clinic_id = NEW.clinic_id
        AND a.patient_id = NEW.patient_id
        AND a.doctor_profile_id = NEW.doctor_profile_id
    ) THEN
      RAISE EXCEPTION 'Consultation appointment must match its patient, doctor and clinic';
    END IF;

  ELSIF TG_TABLE_NAME = 'vitals' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Vitals patient must belong to the same clinic';
    END IF;

    IF NEW.appointment_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.appointments a
      WHERE a.id = NEW.appointment_id
        AND a.clinic_id = NEW.clinic_id
        AND a.patient_id = NEW.patient_id
    ) THEN
      RAISE EXCEPTION 'Vitals appointment must match the patient and clinic';
    END IF;

    IF NEW.consultation_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.consultations c
      WHERE c.id = NEW.consultation_id
        AND c.clinic_id = NEW.clinic_id
        AND c.patient_id = NEW.patient_id
    ) THEN
      RAISE EXCEPTION 'Vitals consultation must match the patient and clinic';
    END IF;

  ELSIF TG_TABLE_NAME = 'prescriptions' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) OR NOT EXISTS (
      SELECT 1 FROM public.doctor_profiles d
      WHERE d.id = NEW.doctor_profile_id AND d.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Prescription patient and doctor must belong to the same clinic';
    END IF;

    IF NEW.consultation_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.consultations c
      WHERE c.id = NEW.consultation_id
        AND c.clinic_id = NEW.clinic_id
        AND c.patient_id = NEW.patient_id
        AND c.doctor_profile_id = NEW.doctor_profile_id
    ) THEN
      RAISE EXCEPTION 'Prescription consultation must match its patient, doctor and clinic';
    END IF;

  ELSIF TG_TABLE_NAME = 'invoices' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Invoice patient must belong to the same clinic';
    END IF;

    IF NEW.appointment_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.appointments a
      WHERE a.id = NEW.appointment_id
        AND a.clinic_id = NEW.clinic_id
        AND a.patient_id = NEW.patient_id
    ) THEN
      RAISE EXCEPTION 'Invoice appointment must match its patient and clinic';
    END IF;

  ELSIF TG_TABLE_NAME = 'payments' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.patients p
      WHERE p.id = NEW.patient_id AND p.clinic_id = NEW.clinic_id
    ) THEN
      RAISE EXCEPTION 'Payment patient must belong to the same clinic';
    END IF;

    IF NEW.invoice_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.invoices i
      WHERE i.id = NEW.invoice_id
        AND i.clinic_id = NEW.clinic_id
        AND i.patient_id = NEW.patient_id
    ) THEN
      RAISE EXCEPTION 'Payment invoice must match its patient and clinic';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.validate_clinic_relationships() FROM PUBLIC;

CREATE TRIGGER validate_appointment_clinic_relationships
BEFORE INSERT OR UPDATE ON public.appointments
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_queue_clinic_relationships
BEFORE INSERT OR UPDATE ON public.queue_entries
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_consultation_clinic_relationships
BEFORE INSERT OR UPDATE ON public.consultations
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_vitals_clinic_relationships
BEFORE INSERT OR UPDATE ON public.vitals
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_prescription_clinic_relationships
BEFORE INSERT OR UPDATE ON public.prescriptions
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_invoice_clinic_relationships
BEFORE INSERT OR UPDATE ON public.invoices
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();

CREATE TRIGGER validate_payment_clinic_relationships
BEFORE INSERT OR UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION private.validate_clinic_relationships();


-- 6B. Protect clinic ownership membership from direct client changes.
-- Clinic owners may manage ordinary members, but only a trusted backend or
-- platform administrator may create, deactivate, remove, or change an OWNER.
-- This prevents self-removal and accidental removal/demotion of the last owner.
CREATE OR REPLACE FUNCTION private.protect_clinic_owner_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Trusted backend calls normally have no end-user auth.uid(); platform admins
  -- are explicitly allowed to perform ownership-membership administration.
  IF (SELECT auth.uid()) IS NULL OR private.is_platform_admin() THEN
    IF TG_OP = 'DELETE' THEN
      RETURN OLD;
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.role = 'OWNER'::public.member_role THEN
      RAISE EXCEPTION 'Only a trusted backend or platform administrator can add an OWNER';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.role = 'OWNER'::public.member_role
       OR NEW.role = 'OWNER'::public.member_role THEN
      RAISE EXCEPTION 'Only a trusted backend or platform administrator can modify OWNER membership';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.role = 'OWNER'::public.member_role THEN
      RAISE EXCEPTION 'Only a trusted backend or platform administrator can remove an OWNER';
    END IF;
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION private.protect_clinic_owner_membership() FROM PUBLIC;
DROP TRIGGER IF EXISTS protect_clinic_owner_membership ON public.clinic_members;
CREATE TRIGGER protect_clinic_owner_membership
BEFORE INSERT OR UPDATE OR DELETE ON public.clinic_members
FOR EACH ROW EXECUTE FUNCTION private.protect_clinic_owner_membership();

-- 7. Revoke direct write privileges for tables whose writes must be server-side.
-- RLS alone is not a substitute for table privileges.
REVOKE INSERT, UPDATE, DELETE ON public.clinic_invitations FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.clinic_subscriptions FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.subscription_clinics FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.trial_events FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.platform_payments FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.ai_interactions FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.ai_usage FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.audit_logs FROM anon, authenticated;

-- A recipient may change only the read flag on their own notification.
REVOKE UPDATE ON public.notifications FROM anon, authenticated;
GRANT UPDATE (is_read) ON public.notifications TO authenticated;

-- Prevent direct table-level role grants from bypassing intended API access.
-- Supabase service_role remains trusted and bypasses RLS by design.
COMMIT;

-- DEPLOYMENT NOTES:
-- 1. Use supabase.rpc('create_clinic_with_owner', {...}) for clinic creation.
-- 2. Invitation acceptance and payment/trial lifecycle changes must be implemented
--    in trusted Edge Functions/RPCs with authorization checks.
-- 3. Do not expose the private schema through PostgREST.
-- 4. This migration sets RLS policies, but application workflows and negative
--    tests must be run before production.
