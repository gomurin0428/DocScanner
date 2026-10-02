# DocRes appearance → illumination gain

- Source: https://github.com/ZZZHANG-jx/DocRes
- Commit: `d3e3a18c7c7ad10e4615ca2eb6a10f83128d8560`
- Checkpoint: `docres.pkl` from the official README-linked demo, https://huggingface.co/spaces/qubvel-hf/documents-restoration/tree/main/checkpoints
- Original checkpoint SHA-256: `1d6a89d754fe1e58ffd1865eab0ef3f03344798d39197b2d9a77ce4fbc8c02fd`
- Tensor-only checkpoint SHA-256: `c72948f7e69945ccfbf8593bc8d34731e64ea2d630a1f09bff90fe9b02ae6707`
- License: MIT, copied to `DocScanner/Resources/DocRes-LICENSE.txt`.
- Core ML weights SHA-256: `75e9244ed11125e043cf5771e3c2b1e7e004456d6b5b96592fa9784803d3f538`.
- Bundled model: approximately 58 MiB, FLOAT32 ML Program, iOS 16+ (app targets iOS 17+).

## Contract

Input `image`: FLOAT32 NCHW `[1,6,512,512]`, range 0…1: BGR image followed by BGR appearance prompt.
Output `restored`: FLOAT32 NCHW `[1,3,512,512]`, BGR, clipped to 0…1 after validity checks.
The input is composited over white. Prompt generation follows upstream: resize to 1024 square, per-channel 7×7 maximum then 21×21 median, `255 - abs(image - background)`, per-channel min/max normalization, and resize to 512 square.

The application smooths the prediction and input (Gaussian σ=3), divides them to estimate illumination gain, clamps that gain to 0.75…4, and applies the bilinearly enlarged gain to the **original pixels**. It never enlarges the network's reconstructed text. Output dimensions and geometry are unchanged. Existing color/grayscale levels and adaptive black-and-white thresholding run afterward. This does not guarantee preservation of every faint mark: tonal clipping and binarization can still remove information; Original remains available.

Missing models, prediction errors, non-finite/out-of-range output, excessive gain clipping (10% of a channel), small inputs, extreme aspect ratios, and low contrast use the existing shading correction. On physical iOS devices, less than 2.2 GB of available **process** memory also selects the fallback, before model loading or inference. This conservative budget is based on the Mac probe and needs device profiling; it is not an OOM guarantee. One lock serializes inference; only the last successful image is cached. The model loads lazily. Camera detection, shutter boundaries, and UVDoc geometry are unchanged.

List thumbnails downscale the source to a 224 px long edge before rotation and conventional filtering. Their dimensions therefore stay below the DocRes minimum and never load the model. Preview and save tasks propagate cancellation to their detached workers; canceled work is discarded without an alert. A production model-load failure is terminal for the app session and asks the user to close and reopen KDocScanner rather than retrying. Deliberately unavailable models, insufficient memory, unsupported inputs, and ordinary prediction/output failures retain the existing rule-based fallback.

## Reproduce

Use separate environments for checkpoint extraction and conversion. `weights_only=True` is required; do not fall back to unrestricted pickle loading. Torch 1.13 cannot safely decode the optimizer metadata in the original checkpoint, so extract the tensors using Torch 2.2.2 first:

```sh
# In an environment with torch==2.2.2 and numpy==1.23.4:
python Tools/DocRes/extract_weights.py /path/to/docres.pkl /path/to/docres-state-only.pt

# In a Python 3.9 conversion environment:
pip install -r Tools/DocRes/requirements.txt
git clone https://github.com/ZZZHANG-jx/DocRes.git /path/to/DocRes
git -C /path/to/DocRes checkout d3e3a18c7c7ad10e4615ca2eb6a10f83128d8560
PYTHONPATH=/path/to/DocRes python Tools/DocRes/convert.py \
  --checkpoint /path/to/docres-state-only.pt \
  --output DocScanner/Resources/DocResAppearance.mlpackage
```

The converter expands population variance into mean-square centered values because coremltools 6.3 does not support `aten::var`. The mathematical LayerNorm operation is unchanged. FLOAT16 was rejected: on one fixed input, mean/max absolute prediction error against the original PyTorch model was 0.0886/0.557. FLOAT32 on the **same tensor** gave mean `2.142336e-7`, max `5.543232e-6`, all finite. Swift preprocessing versus OpenCV differed by mean 0.000682 and max 2/255, due to integer interpolation/normalization rounding.

## Local comparison and limitations

Selection used two fixed, geometrically corrected private document images and one synthetic sheet with known text, thin lines, solid ink/color blocks, and fold-like illumination. No private images or their QR payloads are stored in this repository. This is a diagnostic sample, not a general benchmark or an accuracy guarantee.

| Approach | QR payloads retained on QR-bearing sheet | Synthetic black-and-white foreground F1 |
| --- | ---: | ---: |
| Existing Core Image pipeline | 1/2 | 0.908 |
| DocRes direct binarization | 0/2 | 0.545 |
| FSENet shadow output as smooth gain + existing binarization | 2/2 | 0.937 |
| DocRes appearance as smooth gain + existing binarization (PyTorch) | 2/2 | 0.986 |

F1 treats pixels below 128 as ink, against the saved synthetic foreground mask; antialiased edges affect scores. Both thin horizontal and vertical line groups were retained by the selected black-and-white path. Direct DocRes binarization removed parts of solid graphics and QR codes, so it is not shipped. FSENet was faster in the Mac CPU probe (~0.4 s versus ~6 s for PyTorch DocRes at 512 square), but left more background variation on the synthetic page.

The bundled FLOAT32 Core ML model was also checked using the application's Swift prompt/gain implementation and the same frozen inputs: both QR payloads retained in Enhanced and Black & White; synthetic black-and-white F1 0.986, thin-line recall 1.0, solid-black interior mean 0.0. The second private sheet was inspected for small text but has no QR codes. Inference uses CPU only to retain validated FLOAT32 arithmetic. Mixed-precision variants and smaller 256/320/384 inputs were rejected because only one QR payload was detected after binarization in this sample.

The Mac VM probe took ~5.3 s for inference (~5.6 s including prompt and full-resolution gain), with peak process footprint ~1.83 GB including model compilation/loading. Physical-iPhone latency, peak memory, and live-camera quality remain unverified. Neural Engine acceleration is not enabled. Do not infer iPhone performance from the Mac VM timings. Strong folds and shadows can remain.
