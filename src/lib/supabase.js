import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

// The browser receives only the publishable/anon key. Privileged writes and secrets stay server-side.
export const supabase = url && anonKey ? createClient(url, anonKey) : null;
export const supabaseConfigured = Boolean(supabase);

if (typeof window !== 'undefined') {
  window.SettleFlow = { ...(window.SettleFlow || {}), supabase, supabaseConfigured };
}
