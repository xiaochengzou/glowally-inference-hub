import numpy as np
import triton_python_backend_utils as pb_utils
import onnxruntime as ort


class TritonPythonModel:
    def initialize(self, args):
        model_dir = args["model_repository"]
        version   = args["model_version"]
        # CPU-only — Triton assigns this model to KIND_CPU, keeping GPU free for vLLM
        self.session = ort.InferenceSession(
            f"{model_dir}/{version}/model.onnx",
            providers=["CPUExecutionProvider"],
        )

    def execute(self, requests):
        responses = []
        for request in requests:
            input_ids      = pb_utils.get_input_tensor_by_name(request, "input_ids").as_numpy()
            attention_mask = pb_utils.get_input_tensor_by_name(request, "attention_mask").as_numpy()
            logits = self.session.run(
                ["logits"],
                {"input_ids":      input_ids.astype(np.int64),
                 "attention_mask": attention_mask.astype(np.int64)},
            )[0]
            out = pb_utils.Tensor("logits", logits.astype(np.float32))
            responses.append(pb_utils.InferenceResponse(output_tensors=[out]))
        return responses

    def finalize(self):
        pass
