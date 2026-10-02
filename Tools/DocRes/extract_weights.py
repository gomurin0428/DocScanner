import argparse
import hashlib

import torch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint")
    parser.add_argument("output")
    args = parser.parse_args()
    with open(args.checkpoint, "rb") as source:
        digest = hashlib.sha256(source.read()).hexdigest()
    if digest != "1d6a89d754fe1e58ffd1865eab0ef3f03344798d39197b2d9a77ce4fbc8c02fd":
        raise ValueError("Unexpected official DocRes checkpoint")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    state = checkpoint["model_state"]
    if not all(isinstance(value, torch.Tensor) for value in state.values()):
        raise ValueError("Non-tensor model state")
    torch.save(state, args.output)


if __name__ == "__main__":
    main()
