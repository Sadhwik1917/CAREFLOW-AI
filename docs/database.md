# CAREFLOW AI — Database Architecture

## Database

Firebase Firestore is the primary database.

CAREFLOW uses top-level collections with `clinicId` on clinic-owned records.

## Collections

### users

Stores platform identity information.

Core fields:

- userId
- fullName
- email
- phone
- platformRole
- status
- onboardingStatus
- onboardingStep
- createdAt
- updatedAt

### clinics

Stores clinic information.

Core fields:

- clinicId
- name
- legalName
- phone
- email
- address
- city
- state
- country
- timezone
- currency
- ownerUserId
- status
- createdAt
- updatedAt

### clinic_members

Links users to clinics.

Core fields:

- membershipId
- clinicId
- userId
- role
- status
- joinedAt
- createdAt
- updatedAt

### clinic_invitations

Stores staff/doctor invitations.

Core fields:

- invitationId
- clinicId
- email
- role
- invitedBy
- token
- status
- expiresAt
- acceptedAt
- createdAt

### doctor_profiles

Stores doctor-specific professional information.

Core fields:

- doctorProfileId
- userId
- clinicId
- specialization
- department
- qualification
- experienceYears
- licenseNumber
- consultationFee
- bio
- availability
- status
- createdAt
- updatedAt

### patients

Stores clinic-specific patient records.

Core fields:

- patientId
- clinicId
- userId
- patientNumber
- fullName
- dateOfBirth
- gender
- phone
- email
- address
- emergencyContact
- bloodGroup
- allergies
- status
- createdAt
- updatedAt

`userId` may initially be null because a patient can be registered by clinic staff without a CAREFLOW account.

### appointments

Stores appointments.

Core fields:

- appointmentId
- clinicId
- patientId
- doctorId
- appointmentDate
- startTime
- endTime
- status
- reason
- notes
- createdAt
- updatedAt

### queue_entries

Stores physical clinic queue information.

Core fields:

- queueEntryId
- clinicId
- patientId
- appointmentId
- doctorId
- queueNumber
- status
- checkedInAt
- calledAt
- completedAt
- createdAt
- updatedAt

### consultations

Stores clinical consultations.

Core fields:

- consultationId
- clinicId
- patientId
- doctorId
- appointmentId
- status
- symptoms
- clinicalNotes
- diagnosis
- followUpDate
- createdAt
- updatedAt

### vitals

Stores patient vital measurements.

Core fields:

- vitalId
- clinicId
- patientId
- consultationId
- recordedBy
- temperature
- bloodPressure
- heartRate
- respiratoryRate
- oxygenSaturation
- weight
- height
- createdAt

### prescriptions

Stores prescriptions.

Core fields:

- prescriptionId
- clinicId
- patientId
- doctorId
- consultationId
- notes
- status
- createdAt
- updatedAt

### prescription_items

Stores individual medicines.

Core fields:

- prescriptionItemId
- prescriptionId
- medicineName
- dosage
- frequency
- duration
- instructions
- createdAt

### invoices

Stores clinic invoices.

Core fields:

- invoiceId
- clinicId
- patientId
- invoiceNumber
- subtotal
- discount
- tax
- total
- status
- issuedAt
- dueDate
- createdAt
- updatedAt

### invoice_items

Stores invoice line items.

Core fields:

- invoiceItemId
- invoiceId
- description
- quantity
- unitPrice
- total
- createdAt

### payments

Stores patient-to-clinic payments.

Core fields:

- paymentId
- clinicId
- patientId
- invoiceId
- amount
- paymentMethod
- status
- transactionReference
- paidAt
- createdAt

### notifications

Stores user notifications.

Core fields:

- notificationId
- clinicId
- userId
- type
- title
- message
- read
- createdAt

### ai_interactions

Stores controlled AI interaction metadata.

Core fields:

- interactionId
- clinicId
- userId
- feature
- requestMetadata
- responseMetadata
- createdAt

Sensitive information should not be retained unnecessarily.

### audit_logs

Stores security and accountability events.

Core fields:

- auditLogId
- clinicId
- userId
- action
- resourceType
- resourceId
- metadata
- createdAt

### plans

Stores CAREFLOW subscription plans.

Core fields:

- planId
- name
- description
- clinicMode
- aiEnabled
- aiCreditType
- aiCreditLimit
- maxClinics
- maxDoctors
- maxStaff
- features
- price
- currency
- billingCycle
- trialEnabled
- trialDurationDays
- requiresPaymentMandate
- isActive
- createdAt
- updatedAt

### clinic_subscriptions

Stores clinic subscriptions.

Core fields:

- subscriptionId
- clinicId
- planId
- status
- subscriptionType
- trialStartDate
- trialEndDate
- trialCancelledAt
- autoRenew
- paymentMandateId
- paymentProvider
- billingCycle
- amount
- currency
- nextBillingDate
- startDate
- renewalDate
- cancelledAt
- clinicLimit
- doctorLimit
- staffLimit
- aiEnabled
- aiCreditType
- aiCreditLimit
- createdAt
- updatedAt

### platform_payments

Stores clinic-to-CAREFLOW payment records.

### ai_usage

Tracks AI consumption.

Core fields:

- usageId
- clinicId
- userId
- feature
- creditsUsed
- periodStart
- periodEnd
- createdAt

### trial_events

Tracks subscription trial lifecycle events.

Core fields:

- eventId
- subscriptionId
- clinicId
- eventType
- eventDate
- metadata
- createdAt

## Data Isolation Rule

Every clinic-owned record must contain:

`clinicId`

Access must verify:

`authenticatedUser → clinic membership → role → requested resource`

## Data Deletion

Clinical and financial records should generally use controlled archival or soft deletion rather than unrestricted hard deletion.