# CAREFLOW AI — Development Rules

## Branch Strategy

### main

Stable production-ready code.

### develop

Integration branch.

### feature/*

Feature development branches.

Example:

feature/authentication
feature/patients
feature/appointments

## Rules

1. Do not directly develop on main.
2. Do not force push main.
3. Feature work should use feature branches.
4. Pull requests should be used for merging.
5. Test before creating a pull request.
6. Keep commits focused.
7. Do not commit secrets.
8. Never commit Firebase private keys.
9. Never commit API keys.
10. Use environment variables for secrets.

## Architecture Rules

1. Do not introduce a new database architecture without team agreement.
2. Do not create duplicate collections for the same domain concept.
3. Clinic-owned records must include clinicId.
4. Backend authorization is mandatory for sensitive operations.
5. AI must not directly modify clinical or financial records.
6. Do not bypass RBAC.
7. Reuse existing components and services where possible.
8. Avoid unnecessary dependencies.
9. Keep features modular.
10. Prefer maintainable code over clever code.

## Pull Request

Every PR should explain:

- What changed?
- Why was it changed?
- What was tested?
- Are database changes involved?
- Are security rules affected?
- Are existing workflows affected?

## Secrets

Never commit:

- API keys
- Firebase service account keys
- Payment secrets
- Authentication secrets
- Private credentials

Use environment variables.

## AI Development

AI-generated code must be reviewed before merging.

AI-generated database changes must be checked against the approved architecture.

AI must not be allowed to redesign the system without team approval.