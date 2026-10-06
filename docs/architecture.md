# CAREFLOW AI — Technical Architecture

## 1. Architecture Overview

CAREFLOW AI follows a multi-tenant SaaS architecture.

Each clinic represents a tenant.

Clinic-owned data must be isolated using `clinicId`.

## 2. Technology Stack

### Frontend

React + TypeScript

Responsible for:

- User interface
- Routing
- Forms
- Dashboard
- Client-side state
- API/service interaction

### Backend

Node.js

Responsible for:

- Business logic
- Authorization
- Sensitive operations
- AI orchestration
- Subscription logic
- Validation
- Audit logging

### Authentication

Firebase Authentication.

Supported authentication mechanisms may include:

- Email/password
- Google authentication
- Other providers added later

### Database

Firebase Firestore.

Firestore is the primary application database.

### AI

Gemini is used for AI-assisted functionality.

AI must operate through controlled backend workflows.

### Storage

Firebase Storage may be used for:

- Documents
- Clinic files
- Patient files
- Other approved uploads

## 3. Multi-Tenant Architecture

A clinic is the tenant.

Clinic-owned records must contain:

`clinicId`

Examples:

- patients
- appointments
- consultations
- prescriptions
- invoices
- payments
- doctors
- staff
- notifications

A user can belong to multiple clinics.

The user's role is determined by their membership in a specific clinic.

## 4. Identity and Membership

Users are represented by the `users` collection.

Clinic-specific roles are represented through `clinic_members`.

This allows the same user to have different roles in different clinics.

Example:

User A:

- Owner in Clinic A
- Staff in Clinic B

## 5. Application Layers

The application should follow:

UI
↓
Service Layer
↓
Backend / Business Logic
↓
Firestore / External Services

Sensitive operations must not depend only on frontend validation.

## 6. Security

Security must be enforced at multiple levels:

- Firebase Authentication
- Firestore security rules
- Backend authorization
- Role-based access control
- Tenant isolation
- Audit logging
- Input validation

Hiding a UI button is not considered security.

## 7. AI Architecture

AI requests should follow:

User
↓
Authentication
↓
Authorization
↓
Retrieve required context
↓
Minimize sensitive data
↓
Gemini
↓
Validate response
↓
Human review where required
↓
User

AI must not have unrestricted direct access to Firestore.

AI should not autonomously create or modify clinical or financial records in the MVP.

## 8. Clinical Data

Clinical information is sensitive.

Access must follow least-privilege principles.

Clinical records should use controlled editing and appropriate audit trails.

Important records should generally be archived or soft-deleted rather than permanently deleted.

## 9. Financial Architecture

There are two separate financial systems.

### Clinic → CAREFLOW

Handles:

- subscriptions
- trials
- payment mandates
- plan changes
- SaaS billing

### Patient → Clinic

Handles:

- invoices
- invoice items
- payments
- clinic revenue

These systems must remain logically separate.

## 10. Server Timestamps

Important records should use server-generated timestamps.

## 11. Human-Readable Identifiers

Human-readable identifiers such as:

- patient number
- invoice number
- appointment number

should be separate from database document IDs.

## 12. Architecture Principle

The system should prioritize:

- Security
- Tenant isolation
- Maintainability
- Simplicity
- Scalability
- Auditability
- Clear separation of responsibilities
