"""HF token-classification checkpoint -> app ONNX: legacy torch.onnx.export (opset 17, wrapper `inner`, inputs input_ids/attention_mask
int64 [batch, sequence], output logits) -> onnxruntime quantize_dynamic, per-channel int8 MatMul + quantized embedding Gather.
Reconstructed from the shipped model.int8.onnx graph (producer onnx.quantize, opset 17).  Usage: export_int8.py CKPT_DIR OUT.onnx"""
import sys, os, tempfile, torch
from transformers import AutoModelForTokenClassification
from onnxruntime.quantization import quantize_dynamic, QuantType

class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.inner = m
    def forward(self, input_ids, attention_mask): return self.inner(input_ids=input_ids, attention_mask=attention_mask).logits

ckpt, out = sys.argv[1], sys.argv[2]
m = Wrap(AutoModelForTokenClassification.from_pretrained(ckpt, attn_implementation="eager").eval())
ids = torch.tensor([[0, 100, 200, 300, 2]]); am = torch.ones_like(ids)
fp32 = os.path.join(tempfile.mkdtemp(), "model.fp32.onnx")
torch.onnx.export(m, (ids, am), fp32, input_names=["input_ids", "attention_mask"], output_names=["logits"],
                  dynamic_axes={"input_ids": {0: "batch", 1: "sequence"}, "attention_mask": {0: "batch", 1: "sequence"}, "logits": {0: "batch", 1: "sequence"}},
                  opset_version=17, do_constant_folding=True, dynamo=False)
quantize_dynamic(fp32, out, per_channel=True, weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gather"])
print("wrote", out, os.path.getsize(out))
