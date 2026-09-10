# SUSD Linux Scripts

Static Linux administration script catalog for Sunnyside Unified School District, deployed with Cloudflare Workers Static Assets.

## Repository layout

```text
public/
  _headers
  site.css
  site.js
  <category>/
    <script>.sh
scripts/
  generate-index.mjs
package.json
wrangler.toml
```

Do not hand-maintain category index pages. `scripts/generate-index.mjs` scans `public/` at build time and creates:

- `public/index.html` with all top-level script folders.
- An `index.html` inside every script folder and subfolder.
- Script cards containing metadata, a safe download/run command, a raw-file link, a download link, and a SHA-256 checksum.

## Cloudflare deployment settings

This repository is deployed with Cloudflare Workers Static Assets. `wrangler.toml` points Cloudflare at the generated static site:

```toml
[assets]
directory = "./public"
```

For Git-connected Workers Builds, use:

- Production branch: `main`
- Build command: `npm run build`
- Deploy command: `npx wrangler deploy`
- Root directory: leave blank / repository root
- Custom domain: `linux-scripts.susd12.org`

All scripts and catalog pages under `public/` are static assets.

The build can also be run locally:

```bash
npm run build
```

To generate links for another hostname (for example a test deployment), set `SITE_URL`:

```bash
SITE_URL=https://example.pages.dev npm run build
```

## Adding a script

Create or choose a category under `public/` and add the `.sh` file there. For example:

```text
public/security/harden-ssh.sh
```

The next deployment automatically adds the folder/script to the catalog. Nested folders are supported.

For the best catalog display, place these optional metadata comments immediately after the shebang:

```bash
#!/usr/bin/env bash
# @title: Friendly Script Name
# @description: One-sentence description of what the script does.
# @platforms: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux
# @requires-root: yes
```

`@requires-root` controls whether the generated run command uses `sudo bash`. If metadata is omitted, the generator derives a title from the filename and uses generic Linux metadata.

## Static file headers

`public/_headers` applies baseline security headers to the site. Shell scripts are explicitly served as `text/plain` with revalidation enabled so administrators do not unintentionally receive a stale long-cached script.

## Example script URL

```text
https://linux-scripts.susd12.org/dns/set-dns-to-cloudflare-antimalware.sh
```

Preferred usage is to download, inspect, and then execute a script rather than piping an Internet response directly into a privileged shell.
