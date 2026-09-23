# Fennec visual identity

Fennec's visual language comes from the final mascot art: a cream fennec fox wearing aviator sunglasses and simplified open-back headphones, set against a flat blue sky and orange desert dunes.

Palette:

- Sky: `#2E82CC`
- Dune: `#F47A1F`
- Cream: `#FFE3AB`
- Sand: `#EFB76E`
- Ink: `#1F1F1C`

The product UI uses the sky blue for healthy/listening states and the primary repair action, dune orange for audio/output accents and warnings, and cream sparingly in mascot framing. Native macOS materials and typography remain intact so the app still feels like a system utility.

## Repair fox

`Fennec/Resources/fennec-run.gif` is the owner's approved 1147 × 645 animation,
copied without re-encoding. Its 14 frames total 1.16 s: ten frames at 80 ms and
four at 90 ms. The green palette entry is transparent, not a backdrop to key
out. `FoxRunAsset` retains that alpha and the original, unclamped delays.

The fox faces left in the source. `RepairFoxController` mirrors its drawing
with a horizontal layer transform and moves it left to right. Every frame
uses the same crop: the union of the alpha bounds, `(40, 53, 1087, 544)` in
top-left source pixels. Cropping each pose separately would remove the hop
and shift the body between frames.

At the default width of 240 macOS points, the visible height is about 120
points. The near rear paw moves roughly 220 source pixels backward during
its approximately 0.25 s contact phase (frames 3–6). This gives about 1021
source pixels of travel per 1.16 s loop, or about 194 points/s at the default
size. The art is stylized, so this is a visual calibration rather than exact
foot locking. Wider displays take longer; travel and gait always share one
clock. Do not force every screen into a fixed crossing duration.

The fox signals activity only. It has no success badge, sound, gold accent,
interaction, or extra motion. Settings offers an opt-out and a preview;
macOS Reduce Motion suppresses the crossing entirely.
