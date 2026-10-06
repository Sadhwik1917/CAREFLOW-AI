# CAREFLOW AI — RBAC

## Platform Roles

- PLATFORM_ADMIN
- USER

Clinic roles are stored separately in `clinic_members`.

## Clinic Roles

- OWNER
- DOCTOR
- STAFF
- PATIENT

## OWNER

Can:

- Manage clinic settings
- Manage doctors
- Manage staff
- Manage patients
- Manage appointments
- Manage queue
- Manage billing
- View reports
- Access approved AI features
- Manage clinic subscription

Should not directly modify clinical records without appropriate workflow controls.

## DOCTOR

Can:

- View assigned patients
- View relevant patient history
- Manage consultations
- Record vitals
- Create prescriptions
- Manage follow-ups
- View appointments
- Manage assigned queue

Cannot:

- Manage clinic subscription
- Manage staff
- Manage clinic settings

## STAFF

Can:

- Register patients
- Manage appointments
- Check patients in
- Manage queue
- Create invoices
- Record payments

Cannot:

- Diagnose patients
- Create prescriptions
- Modify clinical records as a doctor

## PATIENT

Can:

- View own profile
- View own appointments
- View permitted medical history
- View prescriptions
- View bills

Cannot:

- Modify clinical records
- Modify invoices
- Access another patient's data

## PLATFORM ADMIN

Can manage platform-level operations such as:

- Clinics
- Users
- Plans
- Subscriptions
- Platform analytics

Sensitive clinical data access must be restricted, justified, and audited.

## Security Principle

RBAC must be enforced server-side and through Firebase security rules.

Frontend permissions alone are not sufficient.