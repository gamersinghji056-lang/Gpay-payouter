# Gpay Payouter / SettleFlow

This folder is prepared to open directly in VS Code and work on with Cline.

## Current state
`index.html` contains the approved working UI prototype.

## Local run
Open PowerShell in this folder:

```powershell
npm install
npm run dev
```

Then open the local URL printed by Vite.

## Cline
Open this entire folder in VS Code, then tell Cline:

`Read CLINE_START_HERE.md first. Inspect the complete project before changing anything. Continue from the existing approved UI and implement the production backend without removing features.`

Do not give Cline only `index.html`; open the whole folder.

## Production target
- Supabase Postgres
- Supabase Auth
- RLS
- Supabase Storage for QR images
- Realtime live views
- Admin/Operator protected access
- Merchant / Agent / User permissions
