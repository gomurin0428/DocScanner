# UVDoc model conversion

The app bundles the 2D prediction head of [UVDoc](https://github.com/tanguymagne/UVDoc),
upstream commit `4c9b82b537057aff2526e6dd118a847cdd072e82`.
The upstream repository ships `model/best_model.pkl` under its root MIT license,
with no separate restriction attached to the checkpoint. The unchanged license
is included in the app as `Resources/UVDoc-LICENSE.txt`.
Training data is not redistributed.

Checkpoint SHA-256: `7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23`.

## Reproduce (macOS, Python 3.9)

Run from the DocScanner repository root. Use a separate checkout for upstream:

```sh
git clone https://github.com/tanguymagne/UVDoc "$HOME/UVDoc"
git -C "$HOME/UVDoc" switch --detach 4c9b82b537057aff2526e6dd118a847cdd072e82
python3 -m venv "$HOME/.venvs/uvdoc"
"$HOME/.venvs/uvdoc/bin/pip" install -r Tools/UVDoc/requirements.txt
PYTHONPATH="$HOME/UVDoc" "$HOME/.venvs/uvdoc/bin/python" Tools/UVDoc/convert.py \
  --checkpoint "$HOME/UVDoc/model/best_model.pkl" \
  --output DocScanner/Resources/UVDoc.mlpackage
```

The checkpoint hash is checked before deserialization. No retraining, network
download at app runtime, image generation, or OCR text reconstruction is involved.
The conversion removes the unused 3D output. Weights and computation use float32
(~30 MiB); Xcode compiles the package into a bundled `.mlmodelc`.

## Tensor contract

- Input `image`: float32 `[1,3,712,488]`, RGB, values 0...1, no mean/std normalization.
- Resize uses half-pixel bilinear sampling, matching `cv2.resize`.
- Output `grid`: float32 `[1,2,45,31]`, X then Y, top-left origin, coordinates -1...1.
- Grid interpolation and source sampling use `align_corners=True` semantics.
- Core ML vs PyTorch on the evaluation photo's identical input: maximum coordinate
  difference `5.96e-7` before boundary adjustment (CPU on this Mac).

`UVDocUnwarper` crops the bounding box of the selected document without first
flattening it. Landscape crops are rotated for inference and restored afterwards.
`UVDocGrid` projects the predicted outer nodes onto the saved edges and blends
the correction over the outer 15% of the grid, retaining the learned interior.
Large edge disagreements (>18% of the crop), nonfinite coordinates, out-of-image
sampling, and folded/near-degenerate cells cause fallback. These are geometry
checks, not a learned confidence score or a guarantee of visual improvement.
Low-contrast and very narrow pages also fall back to boundary/text-line correction.
`Enhanced` then uses the existing shadow/illumination correction.

User evaluation photos and generated comparison files stay outside this repository.
Real-iPhone runtime, memory, and capture quality need device verification.
