# Google Cloud OAuth setup (personal automation cli)

Definitive reference for a process that turned out to be far more
convoluted than it should have been. Written 2026-08-30 after actually
doing it end to end for `the personal Gmail account`, so the next time a new
scope or a new project needs this, it's a checklist instead of a
rediscovery.

Project: **personal automation cli** — originally created for a Google Calendar
sync tool, renamed once it became clear the same OAuth client is the
right vehicle for broader personal Google API access, not just Calendar.

## Why any of this is necessary at all: Internal vs External audience

The root cause of the entire Testing/Production/Branding/Publish dance
below is a single fork in OAuth consent screen setup: **Audience**, a
choice between **Internal** and **External**.

- **Internal** is only offered to a **Google Workspace user** (an
  account that's a member of a Workspace-managed domain). Internal apps
  have no Testing/Production distinction, no Branding requirements, no
  domain hosting, no verification, no refresh-token expiry, ever — for
  any user within that Workspace domain.
- **External** is everyone else's only option, and it's what triggers
  every step in this doc.

Confirmed directly from Google's own UI (attempting to select Internal
on a personal-Gmail-owned project): *"Because you're not a Google
Workspace user, you can only make your app available to external
(general audience) users."*

Critically, **merely holding IAM admin rights on a Cloud Resource
Manager Organization does not make an account a Workspace user** —
these are separate axes. `baleti3266@gmail.com` has full Organization
Admin rights on the Cloud Resource Manager Organization it administers (confirmed via IAM), yet Google's consent screen still refuses
Internal for it, and the account's own `myaccount.google.com` page shows
no "managed by an organization" banner (the standard indicator of real
Workspace membership). A personal Gmail identity cannot be converted
into a Workspace/domain member after the fact, either — Organizations
are inherently domain-based; the closest equivalent (Cloud Identity Free
anchored to a separately-verified custom domain) creates *new*
domain-based accounts, not a retroactive upgrade of an existing
`@gmail.com` address.

## Where the credentials live

- `~/.config/claude-calendar/accounts/<email>/client_secret.json` — the
  OAuth client (type `installed`/Desktop, redirect `http://localhost`).
  One client, reusable for any scope combination — scope is chosen per
  authorization request, not baked into the client.
- `~/.config/claude-calendar/accounts/<email>/token-*.json` — one file
  per credential *purpose*, each holding just a `refresh_token` + `scope` +
  pointer back to `client_secret.json`. Kept separate per purpose
  deliberately, so e.g. a calendar-display token never carries
  Cloud-admin-level scope.
- Both covered by `.config/claude-calendar/accounts/` in
  `~/.git/info/exclude` — this `$HOME` is a public dotfiles repo, and
  `status.showUntrackedFiles=no` is set on it, which means new files
  **do not show up in plain `git status` at all**, ignored or not. Any
  new secret file anywhere in `$HOME` needs an explicit exclude pattern
  added *before* it's written, not discovered later by review.
- `~/.config/claude-cloudflare/credentials-<oauth-account>.env`
  (`CF_ACCOUNT_ID`, `CF_API_TOKEN`) — same treatment, covered by
  `.config/claude-cloudflare/` in the same exclude file.

## Why curl, not `gcloud`

The `google-cloud-cli` AUR package was checked and is genuinely safe (205
votes, not out-of-date, `PKGBUILD` source pins straight to
`dl.google.com` with `sha256sums` — same tarball Google ships for
apt/yum, nothing AUR-specific to distrust). It was skipped anyway because
everything needed — OAuth token exchange, enabling APIs, calling any
Google REST API — is a handful of plain `curl` calls, and a Claude Code
agent driving raw HTTP is more auditable than a 300+MB SDK wrapper around
the same requests. `gcloud` remains a reasonable choice if heavy day-to-day
interactive use ever justifies it; it just wasn't needed here.

## Testing vs Production, and what each requirement actually gates

This is the part that ate the most time, because Google's own UI copy
("Your app's OAuth configuration is incomplete... visit the Branding
page") does not say what's actually missing. Empirically confirmed facts,
in order of discovery:

1. **Testing status is not a blocker for API calls.** `curl`-driven OAuth
   works fine in Testing, for any account listed as a **Test user**
   (Console → OAuth consent screen / Google Auth Platform → Audience →
   Test users). Forgetting to add the account here produces
   `Error 403: access_denied` / "can only be accessed by
   developer-approved testers" — nothing to do with domains or
   verification, just the missing test-user entry.
2. **Testing status's real cost: refresh tokens expire in 7 days**
   (`refresh_token_expires_in: 604798` in the token response, confirmed
   empirically). Fine for on-demand admin use where re-auth is already
   expected each session; a real problem for anything unattended.
3. **Moving to Production removes the 7-day expiry** (confirmed: the
   field disappears from the token response entirely post-Publish) —
   this is the actual reason to bother with any of the below.
4. **The Branding page's real (undocumented in the UI) requirement**,
   confirmed both by Google's own tooltip text on the greyed-out Publish
   button and by other users hitting the identical error message
   ([Google Developer forums thread](https://discuss.google.dev/t/cannot-publish-due-to-error-message-your-apps-oauth-configuration-is-incomplete-you-must-enter-the-missing-information-to-proceed-please-visit-the-branding-page-to-finish-configuring-your-app-even-though-all-required-fields-are-complete/392229)):
   > "Valid app name, support email, homepage url, and privacy policy url
   > are required for switching the app to external production mode."

   App name / support email / developer contact email alone (the fields
   with a visible `*`) are **not** sufficient — Application home page and
   Application privacy policy link are *also* required for Publish, with
   no asterisk shown, and filling them in makes **Authorised domains**
   become required too.
5. Once a domain is added under Authorised Domains and Branding is
   saved, **no separate Search Console verification step was actually
   required** — Publish App became available immediately. (This may be
   specific to using a Public-Suffix-List-registered subdomain like
   `workers.dev` — see below — which Google may accept without a manual
   ownership check the way it would for an arbitrary custom domain.)
6. The **IAP Brands API** (`iap.googleapis.com/v1/projects/{id}/brands`)
   — the only public REST API resource resembling OAuth-consent-screen
   branding — hard-fails with `"Project must belong to an organization"`
   on both `list` and `create`, for any project owned by a personal
   Gmail account (no Workspace org). **This path is closed, don't retry
   it** — Branding has to be set through the Console UI.
7. **Data access → scopes must be explicitly declared** in the Console
   (Add or remove scopes), separately from whatever scope you actually
   request in the auth URL. Google has no record of what data an app
   touches otherwise. This tab also **only lists scopes from APIs
   already enabled** on the project — enable the underlying API first
   (via Service Usage, see below) if a scope isn't showing up in the
   picker.

## Hosting the required Homepage + Privacy Policy pages

Needed: two public HTTPS pages, on a domain listed in Authorised Domains.
Constraints that ruled out the obvious options:

- **A real custom domain** (e.g. an existing Route53-hosted one) works,
  but ties the OAuth app to that domain's registration lifecycle — not
  worth it for a page with no real content, and not needed (see below).
- **GitHub Pages** works technically but means a new public repo (or a
  page bolted onto an existing personal one) sitting on the public
  GitHub profile for a throwaway privacy-policy page — undesirable.
- **A new deSEC (`dedyn.io`) subdomain** (deSEC credentials already exist
  at `~/.local/share/mailserver-migration/secrets/desec.env` from the
  mail server migration project) would have worked, but turned out to be
  unnecessary — see next point.

**What was actually used: a Cloudflare Worker on `*.workers.dev`.**
`workers.dev` (and `pages.dev`) are both on the
[Public Suffix List](https://raw.githubusercontent.com/publicsuffix/list/master/public_suffix_list.dat)
(confirmed by grepping the raw list directly), meaning each
`<name>.workers.dev` is treated as its own independent registrable
domain — same mechanism that makes `github.io` or `herokuapp.com`
subdomains work per-user. This sidesteps deSEC, Route53, and DNS
entirely: Cloudflare *is* both the domain and the host.

Deployed with **zero local binaries** (no `wrangler`/`npx`, by
preference — not a technical requirement) — a single officially
documented REST call:

1. Free Cloudflare account, no card required for Workers' free tier.
2. **My Profile → API Tokens → Create Token**, scoped to
   **Account → Workers Scripts → Edit** only.
3. First-ever visit to `https://dash.cloudflare.com/?to=/:account/workers/workers-and-pages`
   auto-provisions the account's `*.workers.dev` subdomain — this one
   step has no API equivalent and must be done once, in-browser, before
   anything below will work
   (`GET .../workers/subdomain` 404s with
   `"You do not have a workers.dev subdomain"` until this happens).
4. Deploy the script — single PUT, `multipart/form-data`, two parts:
   a `metadata` JSON part (`{"main_module": "worker.js",
   "compatibility_date": "<today>"}`) and a part named after the script
   file itself, `Content-Type: application/javascript+module`:

   ```sh
   curl -X PUT \
     -H "Authorization: Bearer $CF_API_TOKEN" \
     -F "metadata=@metadata.json;type=application/json" \
     -F "worker.js=@/path/to/local/worker.js;filename=worker.js;type=application/javascript+module" \
     "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME"
   ```

   Cloudflare matches the module by the multipart **filename**, not the
   form field name — if the local file isn't literally named `worker.js`
   (e.g. deploying a second, differently-named script from a shared
   scratch dir), this fails with `Uncaught Error: No such module:
   worker.js` unless `filename=worker.js` is set explicitly, as above.

   The Worker script itself is a plain ES module `export default { async
   fetch(request) {...} }` returning different inline HTML per
   `new URL(request.url).pathname` — no build step, no dependencies.
5. Enable the public subdomain for that specific script:

   ```sh
   curl -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
     -H "Content-Type: application/json" -d '{"enabled": true}' \
     "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/subdomain"
   ```
6. Final URL: `https://<script-name>.<account-subdomain>.workers.dev/`.

An unofficial, reverse-engineered "Direct Upload" protocol also exists
for deploying **static assets** (as opposed to a Worker script) purely
via HTTP, involving BLAKE3-hashed manifests and a multi-step JWT
exchange — deliberately not used here. It's undocumented by Cloudflare
and more fragile than just writing 15 lines of JS and using the plain,
officially documented Worker-script upload endpoint above.

Token sanity check before relying on any of this:
`GET https://api.cloudflare.com/client/v4/user/tokens/verify`.

## The actual step-by-step, next time

1. Create/select the GCP project, note its numeric project number
   (needed for Service Usage calls — `cloudresourcemanager.googleapis.com`
   `.../projects/<project-id>` returns it, but only once that API itself
   is enabled).
2. Console → APIs & Services → Credentials → Create OAuth client ID →
   **Desktop app** (gives the loopback `http://localhost` redirect a
   local script can catch itself — a Web-type client needs a registered
   HTTPS redirect on a real server instead).
3. Console → OAuth consent screen (Google Auth Platform) → Audience →
   **Test users** → add the authorizing account. Without this, every
   auth attempt 403s regardless of anything else being configured.
4. Run the curl authorization-code flow (build the
   `accounts.google.com/o/oauth2/v2/auth` URL with the needed
   `scope`, `access_type=offline`, `prompt=consent`; catch the redirect
   with a one-shot local `http.server` on `localhost:<port>`; exchange
   the code at the client's `token_uri`) — this alone is enough for
   on-demand admin use in Testing status, accepting the 7-day refresh
   token lifetime.
5. Only if unattended/long-lived access is actually needed: set up
   Branding (App name, support email, developer contact email, **plus**
   Application home page + Application privacy policy link — the two
   undocumented-as-required fields) and Authorised Domains (the
   Cloudflare Worker trick above), **Verify Branding → Publish
   branding**, then Data access → declare every scope actually used
   (enabling the underlying API first via Service Usage if it doesn't
   appear in the picker), then Audience → **Publish App**.
6. Re-run the same curl auth flow once more post-Publish — same
   "unverified app" click-through as before is expected and fine (we
   are not doing full Google verification review, only Publish) — and
   confirm `refresh_token_expires_in` is now absent from the response.

## Useful raw REST calls, once a token exists

```sh
# refresh an access token
curl -X POST "$TOKEN_URI" \
  -d "refresh_token=$REFRESH_TOKEN" -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" -d "grant_type=refresh_token"

# enable an API on the project (Service Usage)
curl -X POST -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://serviceusage.googleapis.com/v1/projects/<project-number>/services/<api>.googleapis.com:enable"

# confirm project identity/state (Cloud Resource Manager)
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/<project-id>"
```
