# Product Hunt launch kit

This is the prepared listing kit for the first public Fennec release. Publish
only after the public release URL resolves to a notarized build and its signed
update feed. The three current gallery images are brand illustrations based on
the app icon; they are not screenshots of the running app. The text below is
previously prepared copy; the owner has separately filled the live Product Hunt
draft and that text should be preserved.

| Field | Copy or asset |
|---|---|
| Name | Fennec |
| Tagline | A quiet watchdog for crackling Mac audio |
| Product URL | `https://github.com/alexcox245/Fennec` (after the repository is public) |
| Download URL | `https://github.com/alexcox245/Fennec/releases/latest` (after release publication) |
| Thumbnail | `thumbnail-v2.png` (240 × 240; image-generated from the app icon as a reference) |
| Gallery 1 | `gallery-01-listening-v2.png` (1619 × 971; walking fox desert landscape and social preview) |
| Gallery 2 | `gallery-02-signal-v2.png` (1620 × 971; seated fox and failure signal) |
| Gallery 3 | `gallery-03-repair-v2.png` (1619 × 971; Figma-inspired duotone mascot and repair choice) |
| Video demo | `fennec-audio-demo.mp4` (31 seconds; 1920 × 1080, 30 fps; title card, then large step captions: Listening for crackling, Crackle detected, Resolving…, Donesies; the owner's track "Cyberchill" with simulated crackle and 1.5 seconds of silence). Upload to YouTube; thumbnail `fennec-audio-demo-youtube-thumbnail.png` (1280 × 720) |
| Animated preview | `fennec-audio-demo-preview.gif` (silent loop showing the fox crossing; keep it out of the three-image gallery) |
| Pricing | Free, open source (MIT) |
| Maker | Repository owner `alexcox245`; verify the Product Hunt account before posting |

**Description**

Fennec listens for a specific Mac audio failure that can leave playback
crackling. When the signal repeats, it can ask you first or restart the sound
service with your approval. It checks whether the repair holds, stands down
when it doesn't, and keeps its logs on your Mac.

**First comment**

I built Fennec for the crackle that sometimes survives even after a heavy Mac
workload ends. It watches the output for missed audio deadlines and can restart
the sound service without closing your apps. You can choose automatic repair
or approve each one. It pauses during calls and recording, skips Bluetooth by
default, and stops retrying when a restart does not help. There is no account
or telemetry. The code and removal instructions are on GitHub. I would like
to hear which Mac and output device you use, and whether the signal matches
what you actually hear.

Before posting, replace any Product Hunt field that requires the direct
download URL with the verified `Fennec.zip` asset URL. Check the public links,
the displayed crop of all three gallery illustrations, and the final version/build number.

## Current media draft (2026-10-03)

The four `-v2.png` files are the current Product Hunt media set. The earlier
`thumbnail.png`, `gallery-listener.png`, and `gallery-repair.png` remain for
comparison. The v2 images are raster illustrations generated with the master
icon and the [Fennec Figma file](https://www.figma.com/design/YqkjbOVhkJV7RvC6Lk5vHP/Fennec?node-id=328-30)
as character/style references. The set uses three different compositions:
walking landscape, seated landscape, and a duotone mascot graphic. They are
not vector source files or app screenshots. Generation prompts are recorded in
`PROMPTS.md`.

The [Product Hunt launch guide](https://www.producthunt.com/launch/preparing-for-launch)
recommends a square 240 × 240 thumbnail and 1270 × 760 gallery images. The
live draft requests at least three gallery images and uses the first as its
social preview. Figma's [graphic design principles](https://www.figma.com/resource-library/graphic-design-principles/)
support the set's large type, strong contrast, alignment, repeated mascot, and
open space. The Product Hunt draft already contains owner-written listing copy;
the media set does not replace that copy.

The [Product Hunt draft](https://www.producthunt.com/products/fennec-3?launch=fennec-3)
was saved on 2026-10-03 with the v2 thumbnail and three gallery images in the
order listed above. Product Hunt displayed “This product is a draft and is not
scheduled for a launch yet.” Pricing is Free and Alex Cox is listed as maker.
The owner-written tagline, description, and first comment were preserved.

At the time of the draft review, `https://fennec.ludicrousdesigns.com/` (the
draft's product URL) returned `DNS_PROBE_FINISHED_NXDOMAIN`. Verify that page
and the public download before publishing. The draft has not been submitted
or scheduled for launch.

## Illustrative audio demo

`fennec-audio-demo.mp4` is a 31-second, 16:9 video for Product Hunt's gallery,
which accepts YouTube links only (the full URL, not private). It opens on the
title card, then plays on a stylized Mac desktop with a flat desert wallpaper in
the master-art palette. Each step has a large caption beside the app icon so it
reads when the video plays as a small thumbnail:

| Time | Caption and picture | Sound |
|---|---|---|
| 0–3.4 s | Title card: icon, name, tagline, "Free · Open source · macOS" | "Cyberchill", clean |
| 4–8.6 s | **Listening for crackling**; smooth cream line under "Now playing" | Clean |
| 8.6–12.5 s | **Crackle detected**; orange dropouts and bursts, red menu-bar fennec | Synthesized crackle from 8 s |
| 12.5–18.5 s | **Resolving…**; the approved run cycle walks the bottom of the screen at its own ground speed | Crackle, then exactly 1.5 s of silence from 17 s |
| 19–27 s | **Donesies**, with the app's real notification; smooth cream line | The song carries on, clean |
| 27–31 s | Title card again | Fade out |

The music is the owner's own track "Cyberchill"; its file is not in the
repository. The crackle is synthesized from underruns, repeated buffers, noise
bursts and pops. Every glitch on the line is the same event you hear, and the
line's height follows the track's own loudness; its calm shape is a fixed low
tone, because the literal low band goes flat whenever the bass drops out. The footer reads "Illustrative demo ·
simulated audio"; the video does not show a live repair or claim that one held.

Rebuild with Pillow, NumPy and ffmpeg:

```bash
python3 Brand/ProductHunt/render-video-demo.py --track "/path/to/1 - Cyberchill.wav"
```

`--still 12.4` writes a single frame for review instead of encoding. The same
run writes the silent animated `fennec-audio-demo-preview.gif` and the YouTube
thumbnail. Keep the three banners as the only gallery images; the video goes in
Product Hunt's separate video field once it is on YouTube.

Three image-generated YouTube thumbnail alternatives are ready at 1280×720:

| File | Concept |
|---|---|
| `fennec-youtube-thumbnail-portrait.png` | Close listener portrait; “Mac audio crackling?” |
| `fennec-youtube-thumbnail-run.png` | Full-body running fox; “Crackle. Silence. Sound.” |
| `fennec-youtube-thumbnail-poster.png` | Cream editorial poster; “Hear the reset.” |

All three use image-generated Fennec-style art with typography added afterward
for exact spelling and small-size legibility. The original
`fennec-audio-demo-youtube-thumbnail.png` remains available until the owner
chooses a replacement.
