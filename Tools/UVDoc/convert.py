import argparse
import hashlib

import coremltools as ct
import torch

from model import UVDocnet


class GridOnly(torch.nn.Module):
    def __init__(self, network):
        super().__init__()
        self.network = network

    def forward(self, image):
        return self.network(image)[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    with open(args.checkpoint, "rb") as checkpoint:
        digest = hashlib.sha256(checkpoint.read()).hexdigest()
    if digest != "7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23":
        raise ValueError("Unexpected UVDoc checkpoint")
    torch.set_num_threads(4)
    network = UVDocnet(num_filter=32, kernel_size=5)
    network.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True)["model_state"])
    network.eval()
    wrapper = GridOnly(network).eval()
    example = torch.zeros(1, 3, 712, 488)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="image", shape=example.shape)],
        outputs=[ct.TensorType(name="grid")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    converted.author = "Tanguy Magne et al. (UVDoc); Core ML conversion for DocScanner"
    converted.license = "MIT; see UVDoc-LICENSE.txt"
    converted.short_description = "UVDoc 2D backward grid, RGB [0,1] NCHW 1x3x712x488 → 1x2x45x31, xy in [-1,1], top-left origin, align_corners=True"
    converted.user_defined_metadata["upstream_commit"] = "4c9b82b537057aff2526e6dd118a847cdd072e82"
    converted.user_defined_metadata["checkpoint_sha256"] = digest
    converted.save(args.output)


if __name__ == "__main__":
    main()
