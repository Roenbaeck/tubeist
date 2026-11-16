# Tubeist website

A self-contained static site for **https://www.uptochange.com/tubeist/**,
matching the four-page structure and visual family of the Corridorium and
Eye the Isles websites. Published by **Up to Change AB**, developed by
**Lars Rönnbäck**, with **support@uptochange.com** as the support contact.

The public files are `index.html`, `support.html`, `privacy-policy.html`,
`licence.html`, and `assets/`. There is no build step, JavaScript, package
installation, external font, analytics, form or third-party embed.
The FAQ uses native HTML disclosure controls. The site works at the root
of a static server or beneath `/tubeist/`.

## Upload

Extract `AppStore/Website.zip` into the server's `tubeist/` web directory.
Keep `assets/` alongside the four HTML files. The archive contains only
public files; this README is not included.

Alternatively, from the Tubeist repository root, replace the server and
document-root values:

```sh
rsync -av --exclude README.md AppStore/Website/ USER@SERVER:/PATH/TO/WEBROOT/tubeist/
```

The trailing slash copies the folder contents. The command does not remove
server files. Use ordinary static-file serving, HTTPS and the normal
`/tubeist` to `/tubeist/` directory redirect. No SPA fallback is needed.
Serve HTML, CSS, WebP, PNG, JPEG and TXT with their standard MIME types.

## Links to use after deployment

First open all four public pages and check the screenshots, App Store link,
email link and support disclosures. Then update the relevant services:

| Setting | URL |
| --- | --- |
| App Store Connect marketing | `https://www.uptochange.com/tubeist/` |
| App Store Connect support | `https://www.uptochange.com/tubeist/support.html` |
| App Store Connect privacy | `https://www.uptochange.com/tubeist/privacy-policy.html` |
| App licence / use | `https://www.uptochange.com/tubeist/licence.html` |

The website is live at the URLs above. The app source links to the new
privacy policy from Settings → Privacy and Credentials, and to the homepage,
support and licence from Settings → About Tubeist. These native links will
ship with the next app build. The repository privacy policy also directs
readers of existing app versions to the current hosted policy.

App Store Connect marketing, support and privacy URLs are managed separately
from the app binary. Updating these URLs does not replace a submitted build.
Google OAuth branding and any old subside.com pages are separate migration
steps, described below.

If Tubeist's Google OAuth branding uses subside.com, update its homepage,
privacy and terms URLs to these deployed pages through Google Cloud's
normal domain-verification process. Keep existing OAuth redirect URIs and
credentials unchanged; a marketing-site move does not call for changing
the app's login callback.

Replace the outdated subside.com pages or add permanent redirects for
Tubeist's old URLs once the new site has been checked:

- Tubeist homepage → `https://www.uptochange.com/tubeist/`
- `privacy.html` → `https://www.uptochange.com/tubeist/privacy-policy.html`
- `terms.html` → `https://www.uptochange.com/tubeist/licence.html`

Apply only redirects appropriate to that domain's other uses. Removing the
old personal/non-commercial-only restriction is intentional: the owner
explicitly permits personal and commercial use, including paid productions
and monetized broadcasts, without an additional commercial fee or royalty.

## Content and maintenance

The app is already available, so the homepage has a permanent link to its
real App Store listing. There is no pre-release toggle. Prices are not
hard-coded: recording and streaming are free; Styles and Effects is the
optional one-time purchase, with the regional price shown by Apple.

Product and support copy is based on the repository README, current
Settings UI, privacy policy, and Watch/highlights documentation. It covers
direct YouTube HLS streaming, optional Google authorization, recording,
overlays, buffer trade-offs, and foreground camera requirements. It does
not promise Twitch, generic RTMP output, unlimited outage recovery or
background camera capture.

The privacy page separates app data from website hosting and support
email. Confirm the hosting provider's actual access-log and retention
configuration when deploying. Keep the site policy, GitHub policy,
in-app links and App Store privacy answers consistent as behavior changes.

The use-and-licence page makes commercial permission explicit, links the
App Store licence and YouTube terms, and includes an unchanged copy of the
repository's MIT licence. It does not add a new personal-use restriction
or require attribution in recordings.

## Asset sources

All screenshots are real repository assets, resized and compressed without
retouching app content. The Watch picture is an existing promotional
composite and is described as such in its alternative text.

| Website asset | Repository source |
| --- | --- |
| `camera.webp`, `camera-small.webp` | `screenshots/6.3-inch/iPhone16_Pro_Without_effects.PNG` |
| `rotoscope.webp` | `screenshots/6.3-inch/iPhone16_Pro_Rotoscope_Saturation.PNG` |
| `blackbright.webp` | `screenshots/6.3-inch/iPhone16_Pro_Blackbright_Grain.PNG` |
| `watch.webp` | `screenshots/6.3-inch/AppleWatch.png` |
| Icons | `Tubeist/Assets.xcassets/AppIcon.appiconset/TubeistIcon.png` |
| `social.jpg` | Layout of the camera screenshot and existing app icon |
| `source-licence.txt` | `LICENSE`, unchanged |

The YouTube demo playlist is linked, not embedded. Visitors contact YouTube
only after following the link. All visual assets required by the pages are
included in the upload ZIP.

## Preview and refresh the ZIP

From the repository root:

```sh
python3 -m http.server 8767 --bind 127.0.0.1 --directory AppStore/Website
```

Open `http://127.0.0.1:8767/`. Rebuild the ZIP after editing public files:

```sh
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
root = Path('AppStore/Website')
files = [root / name for name in (
    'index.html', 'support.html', 'privacy-policy.html', 'licence.html'
)] + sorted((root / 'assets').glob('*'))
with ZipFile('AppStore/Website.zip', 'w', ZIP_DEFLATED) as archive:
    for path in files:
        if path.is_file() and not path.name.startswith('.'):
            archive.write(path, path.relative_to(root))
PY
```

## Delivery checks

Checked all four pages and their local links/anchor targets, image metadata,
canonical URLs and ZIP contents. Browser review covered desktop, tablet and
narrow phone layouts (320–1365 CSS pixels), including the support FAQ,
privacy page and commercial-use text. No horizontal overflow was found.
The preview in `AppStore/Website-preview.jpg` is for local review and is
not part of the public upload.
