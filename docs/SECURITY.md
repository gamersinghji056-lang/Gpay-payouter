# Security Requirements

- Real Admin/Operator authentication.
- Direct admin URL cannot bypass authentication.
- RLS/backend authorization is mandatory.
- GPay passwords encrypted at rest.
- Encryption/service-role secrets never shipped to browser.
- Private QR storage with authorized/signed access.
- Merchant/Agent/User share tokens must be high entropy and revocable.
- Audit sensitive credential access and financial corrections.
- Share pages expose only fields permitted for that role.
