# Repository Guidelines

## Project Structure & Module Organization

This repository is a Vite-based prototype for Gpay Payouter / SettleFlow. The approved working UI lives in `index.html`; preserve existing screens and behavior when refactoring. Project notes are in `README.md` and `CLINE_START_HERE.md`. Domain references live under `docs/`, especially `docs/ACCOUNTING.md` and `docs/SECURITY.md`. Supabase database setup is in `supabase/schema.sql`. Treat `Gpay-payouter-Codex-Ready/` as a reference copy unless a task explicitly targets it.

## Build, Test, and Development Commands

- `npm install`: install Vite and Supabase client dependencies.
- `npm run dev`: start the local Vite development server.
- `npm run build`: produce the production build in `dist/`.
- `npm run preview`: serve the built output locally for verification.

There is currently no configured test script in `package.json`.

## Coding Style & Naming Conventions

Use the existing plain HTML/CSS/JavaScript style in `index.html` unless a framework is explicitly requested. Keep edits focused and avoid removing approved prototype features. Use two-space indentation for HTML, CSS, JSON, and JavaScript additions. Prefer descriptive names for UI state, ledger calculations, and Supabase tables or columns; avoid abbreviations except established terms like `INR`, `USDT`, `GPay`, and `RLS`.

## Testing Guidelines

No automated test framework is configured yet. For UI changes, run `npm run dev` and manually verify affected Admin, Operator, Merchant, Agent, and User flows. Run `npm run build` before handing off changes. If tests are added, use a clear `tests/` or colocated `*.test.js` pattern and add an `npm test` script.

## Commit & Pull Request Guidelines

This working directory does not expose Git history, so no local commit convention can be inferred. Use concise, imperative commit subjects such as `Add Supabase settlement schema` or `Fix merchant balance display`. Pull requests should include a summary, affected views or roles, verification steps, linked issues, and screenshots for visible UI changes.

## Security & Configuration Tips

Copy `.env.example` to `.env` for local Supabase configuration and never commit `.env`. Do not ship service-role keys, encryption secrets, or privileged credentials to browser code. Follow `docs/SECURITY.md`: enforce real auth, RLS/backend authorization, private QR storage, revocable high-entropy share tokens, and auditing for credential access or financial corrections.

## Accounting Rules

Keep settlement and recovery calculations centralized. Follow `docs/ACCOUNTING.md`; Admin, Merchant, Agent, and User views must use the same calculation logic for balances, frozen funds, settlements, recoveries, and holding amounts.
