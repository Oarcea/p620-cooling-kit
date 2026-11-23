"""P100 power virus via torch jiterator (NVRTC JIT for sm_60) + cuBLAS HGEMM.
Usage: CUDA_VISIBLE_DEVICES=<uuid> python gpu_burn_jit.py <mode> <seconds>
modes: fma  - dense FP32 FMA chains (8 independent accumulators per thread)
       gemm - FP16 cuBLAS GEMM (~170 W on its own)
       both - fma kernel and GEMM on two streams concurrently
"""
import sys, time, torch
from torch.cuda import jiterator

mode, secs = sys.argv[1], float(sys.argv[2])
d = torch.device("cuda:0")

code = r"""
template <typename T> T burn(T x) {
    float a = x, b = x + 0.5f, c = x + 0.25f, e = x + 0.125f;
    float f = x + 0.0625f, g = x + 0.03125f, h = x + 0.015625f, k = x + 0.0078125f;
    #pragma unroll 16
    for (int i = 0; i < 8192; ++i) {
        a = fmaf(a, 0.9999f, 0.0001f); b = fmaf(b, 0.9998f, 0.0002f);
        c = fmaf(c, 0.9997f, 0.0003f); e = fmaf(e, 0.9996f, 0.0004f);
        f = fmaf(f, 0.9995f, 0.0005f); g = fmaf(g, 0.9994f, 0.0006f);
        h = fmaf(h, 0.9993f, 0.0007f); k = fmaf(k, 0.9992f, 0.0008f);
    }
    return a + b + c + e + f + g + h + k;
}
"""
burn = jiterator._create_jit_fn(code)
stream_code = "template <typename T> T axpb(T x, T y) { return x * 1.0001f + y; }"
axpb = jiterator._create_jit_fn(stream_code)

# torch.empty needs no kernel; contents are irrelevant for a power load
x = torch.empty(56 * 2048 * 16, device=d, dtype=torch.float32)
n = 8192
A = torch.empty(n, n, device=d, dtype=torch.float16); B = torch.empty(n, n, device=d, dtype=torch.float16)
s1, s2 = torch.cuda.Stream(d), torch.cuda.Stream(d)
if "hbm" in mode:   # 3 x 1 GB fp32 arrays: 2 reads + 1 write per element
    X = torch.empty(256 * 1024 * 1024, device=d); Y = torch.empty_like(X); Z = torch.empty_like(X)

end = time.time() + secs
rounds = 0
while time.time() < end:
    if mode in ("fma", "both"):
        with torch.cuda.stream(s1):
            y = burn(x)
    if "hbm" in mode:
        with torch.cuda.stream(s1):
            for _ in range(4):
                torch.cuda.jiterator  # noqa
                Z = axpb(X, Y)
    if mode in ("gemm", "both", "gemm+hbm"):
        with torch.cuda.stream(s2):
            for _ in range(4):
                torch.mm(A, B)
    torch.cuda.synchronize(d)
    rounds += 1
flops = x.numel() * 8192 * 8 * 2 * rounds / secs / 1e12 if mode in ("fma", "both") else 0
print(f"{mode}: {rounds} rounds, FMA part ~{flops:.2f} TFLOPS")
