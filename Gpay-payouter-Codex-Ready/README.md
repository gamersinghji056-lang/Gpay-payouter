# Gpay-payouter — Codex Ready

This package contains the latest approved standalone prototype plus the instructions Codex must follow before productionizing it.

## Start locally
```powershell
npm install
npm run dev
```
Open the Vite URL printed in the terminal.

## First Codex instruction
Paste this into Codex:

`Read CODEX_START_HERE.md completely. Then inspect the entire repository and index.html. Do not change any files yet. First report what currently works, the exact production gaps, the files you plan to change, and your Supabase/Auth/RLS/TRON implementation plan. Preserve the approved UI and keep Deposit Based and Commission Based user logic completely separate.`

## Prototype note
`index.html` is still a browser/localStorage prototype. It is deliberately included as the functional source of truth for the approved UI and business logic. Production security/storage/blockchain work must move to server-backed architecture.
