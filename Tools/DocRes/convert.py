import argparse
import hashlib

import coremltools as ct
import torch

from models.restormer_arch import LayerNorm, Restormer, WithBias_LayerNorm


class ExportLayerNorm(WithBias_LayerNorm):
    def forward(self, value):
        centered = value - value.mean(-1, keepdim=True)
        variance = centered.square().mean(-1, keepdim=True)
        return centered / torch.sqrt(variance + 1e-5) * self.weight + self.bias


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    with open(args.checkpoint, "rb") as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    if digest != "c72948f7e69945ccfbf8593bc8d34731e64ea2d630a1f09bff90fe9b02ae6707":
        raise ValueError("Unexpected DocRes tensor-only checkpoint")
    torch.set_num_threads(4)
    network = Restormer(
        inp_channels=6, out_channels=3, dim=48, num_blocks=[2, 3, 3, 4],
        num_refinement_blocks=4, heads=[1, 2, 4, 8], ffn_expansion_factor=2.66,
        bias=False, LayerNorm_type="WithBias", dual_pixel_task=True,
    )
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    network.load_state_dict({key.removeprefix("module."): value for key, value in state.items()})
    for module in network.modules():
        if isinstance(module, LayerNorm):
            replacement = ExportLayerNorm(module.body.weight.numel())
            replacement.load_state_dict(module.body.state_dict())
            module.body = replacement
    network.eval()
    sample = torch.ones(1, 6, 512, 512)
    with torch.inference_mode():
        traced = torch.jit.trace(network, sample, check_trace=False)
    converted = ct.convert(
        traced, convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=sample.shape)],
        outputs=[ct.TensorType(name="restored")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    converted.author = "Jiaxin Zhang et al. (DocRes); Core ML conversion for DocScanner"
    converted.license = "MIT; see DocRes-LICENSE.txt"
    converted.short_description = "DocRes appearance: BGR image + BGR appearance prompt, [0,1] NCHW 1x6x512x512 to BGR 1x3x512x512"
    converted.user_defined_metadata["upstream_commit"] = "d3e3a18c7c7ad10e4615ca2eb6a10f83128d8560"
    converted.user_defined_metadata["original_checkpoint_sha256"] = "1d6a89d754fe1e58ffd1865eab0ef3f03344798d39197b2d9a77ce4fbc8c02fd"
    converted.user_defined_metadata["state_checkpoint_sha256"] = digest
    spec = converted.get_spec()
    output = spec.description.output[0]
    if output.name != "restored":
        raise ValueError("Unexpected DocRes output feature")
    del output.type.multiArrayType.shape[:]
    output.type.multiArrayType.shape.extend([1, 3, 512, 512])
    converted = ct.models.MLModel(
        spec,
        weights_dir=converted.weights_dir,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    converted.save(args.output)


if __name__ == "__main__":
    main()
