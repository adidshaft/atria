# Face-Off universal-link fallback (zero-cost hosting)

Static page that renders a Recovery Face-Off challenge for people WITHOUT the
app, plus the Associated Domains plumbing so `https://` challenge links open
Atria directly when it IS installed. No server logic: the payload rides the URL
fragment (`#...`), which browsers never send to the host, and is decoded
client-side with `DecompressionStream('deflate-raw')`.

## Publish (once, ~5 minutes, $0)

1. Create a public GitHub repo (e.g. `atria-pages`) and enable GitHub Pages.
2. Copy `index.html` to `faceoff/index.html` in that repo.
3. Copy `apple-app-site-association` (below) to `.well-known/apple-app-site-association`
   — served as `application/json`, no extension (GitHub Pages does this correctly).
4. Replace `TEAMID` with the Apple Developer Team ID.
5. In Xcode: Signing & Capabilities → add **Associated Domains** →
   `applinks:<user>.github.io`.
6. In `AtriaFaceOff.swift`, add the https form of the challenge link:
   `https://<user>.github.io/faceoff/#<payload>` alongside the `atria://` form.

## apple-app-site-association template

```json
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appIDs": ["TEAMID.com.adidshaft.atria"],
        "components": [
          { "/": "/faceoff/*", "comment": "Recovery Face-Off challenge links" }
        ]
      }
    ]
  }
}
```

## Test without publishing

Open `index.html#<payload>` locally in Safari (the fragment decoder works from
`file://`). Generate a payload from the app's "Challenge a friend" link — the
part after `d=`.
