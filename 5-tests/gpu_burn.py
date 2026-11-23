"""P100 stress load using cuBLAS only (env_isaaclab torch lacks sm_60 elementwise kernels).
Usage: CUDA_VISIBLE_DEVICES=<uuid> python gpu_burn.py <mode> <seconds>
modes: fp32  - SGEMM 8192^2
       fp16  - HGEMM 8192^2 (P100 ~2x FP32 rate)
       mix   - HGEMM on one stream + large device-to-device copies on another (compute + HBM2)
"""
import sys, time, torch
mode, secs = sys.argv[1], float(sys.argv[2])
if mode.startswith("hfp16"):   # true FP16 accumulate (CUBLAS_COMPUTE_16F): P100 double-rate FP16
    torch.backends.cuda.matmul.allow_fp16_accumulation = True
    mode = mode[1:]
d = torch.device("cuda:0")
dt = {"fp16": torch.float16, "mix": torch.float16, "fp16x2": torch.float16,
      "fp64": torch.float64, "fp64x2": torch.float64}.get(mode, torch.float32)
if mode.endswith("x2"):           # two concurrent GEMM streams, larger matrices
    n = 12288 if dt == torch.float16 else 8192
    a = torch.randn(n, n, dtype=torch.float32).to(dt).to(d); b = torch.randn(n, n, dtype=torch.float32).to(dt).to(d)
    streams = [torch.cuda.Stream(d), torch.cuda.Stream(d)]
    end = time.time() + secs; gemms = 0
    while time.time() < end:
        for s in streams:
            with torch.cuda.stream(s):
                torch.mm(a, b); torch.mm(a, b)
        gemms += 4
        torch.cuda.synchronize(d)
    print(f"{mode}: {gemms * 2 * n**3 / secs / 1e12:.2f} TFLOPS")
    sys.exit(0)
n = 8192
a = torch.randn(n, n, dtype=torch.float32).to(dt).to(d); b = torch.randn(n, n, dtype=torch.float32).to(dt).to(d)  # random data: real switching activity
if mode == "mix":
    src = torch.empty(512 * 1024 * 1024, dtype=torch.uint8, device=d)   # 512 MB
    dst = torch.empty_like(src)
    s2 = torch.cuda.Stream(d)
end = time.time() + secs
gemms = 0
while time.time() < end:
    for _ in range(4):
        torch.mm(a, b); gemms += 1
    if mode == "mix":
        with torch.cuda.stream(s2):
            dst.copy_(src)          # cudaMemcpyAsync D2D, no custom kernel
    torch.cuda.synchronize(d)
el = secs
print(f"{mode}: {gemms * 2 * n**3 / el / 1e12:.2f} TFLOPS")
