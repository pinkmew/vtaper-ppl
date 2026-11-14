# V-Taper PPL

A 6-day push/pull/legs cut plan as an offline web app.

On iPhone: open the GitHub Pages link in Safari, tap Share, then Add to Home Screen.
After the first open it works with no signal. Set ticks are saved on the phone.

## Update 2: chat and notifications
1. Run `supabase-update-2.sql` in Supabase → SQL Editor (safe to run more than once).
2. Deploy `supabase/functions/push/index.ts` as an Edge Function called `push`, with JWT verification off.
3. Add Edge Function secrets `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` (`mailto:` plus your email). The private key is never stored in this repo.

## Update 3: codes
Run `supabase-update-3.sql` in Supabase → SQL Editor. Codes are stored as SHA-256 fingerprints only.
To add a code later, in the SQL Editor: `select public.add_code('YOUR-CODE', '{"gems": 250}', null, '250 gems');`
Rewards can combine `gems`, `chest` ("bronze", "silver" or "gold"), `pet`, `mythic` ("random") and `items` ([{"kind": "frame", "id": "circle"}]).
The third value limits how many people can use it (null means no limit).
