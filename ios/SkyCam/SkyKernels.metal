#include <CoreImage/CoreImage.h>
using namespace metal;

// Core Image kernels for the native HDR capture. Inputs are linear light (Core Image working space).
// skyGrade mirrors the web preview shader in index.html so the saved photo matches what was framed.
extern "C" {
namespace coreimage {

static float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static float mx3(float3 c) { return max(c.r, max(c.g, c.b)); }

// Exposure merge: the metered frame by default, the darker frame where it is near clipping (sky, sun-lit cloud),
// the brighter frame in deep shadow. k* scale each frame to the same exposure.
float4 skyMerge(sample_t dark, sample_t mid, sample_t bright, float kd, float km, float kb) {
    float3 m = mid.rgb * km, d = dark.rgb * kd, b = bright.rgb * kb;
    float wd = smoothstep(0.55, 0.92, mx3(mid.rgb));
    float3 c = mix(m, d, wd);
    float wb = (1.0 - smoothstep(0.004, 0.04, lum(mid.rgb))) * (1.0 - smoothstep(0.55, 0.92, mx3(bright.rgb)));
    c = mix(c, b, wb);
    return float4(c, 1.0);
}

// GND filters (A = centre xy + normal, B = stops, transition, type; C = tint), white balance, highlight shoulder,
// then the sky look in display gamma: l1 = (contrast, dehaze, vibrance, polariser), l2 = (shadows, highlights, mono).
float4 skyGrade(sample_t s, float2 size, float gn,
                float4 a0, float4 a1, float4 a2, float4 a3, float4 a4,
                float4 b0, float4 b1, float4 b2, float4 b3, float4 b4,
                float3 c0, float3 c1, float3 c2, float3 c3, float3 c4,
                float3 wb, float4 l1, float4 l2, destination dest) {
    float4 A[5] = {a0, a1, a2, a3, a4};
    float4 B[5] = {b0, b1, b2, b3, b4};
    float3 C[5] = {c0, c1, c2, c3, c4};
    float2 p = dest.coord();
    float2 sp = float2(p.x / size.x, 1.0 - p.y / size.y);   // screen coords, y down, like the preview
    float m = min(size.x, size.y);
    float st = 0.0;
    float3 ti = float3(1.0);
    for (int i = 0; i < 5; i++) {
        if (float(i) >= gn) break;
        float d = dot((sp - A[i].xy) * size / m, A[i].zw);
        float f = max(B[i].y, 0.003);
        float k;
        if (B[i].z < 0.5) k = smoothstep(-f, f, d);
        else if (B[i].z < 1.5) k = smoothstep(-f * 0.15, f * 0.15, d);
        else k = smoothstep(-0.012, 0.012, d) * mix(1.0, 0.28, smoothstep(0.0, f * 2.0, d));
        st += B[i].x * k;
        ti *= mix(float3(1.0), C[i], k);
    }
    float3 l = max(s.rgb, float3(0.0)) * exp2(-st) * wb * ti;
    float3 x = max(l - 0.6, float3(0.0));
    l = min(l, float3(0.6)) + 0.4 * (1.0 - exp(-x / 0.4));   // soft shoulder: merged HDR highlights roll off, never clip hard
    float3 c = pow(l, float3(1.0 / 2.2));

    float con = l1.x, haze = l1.y, vib = l1.z, cpl = l1.w, sh = l2.x, hi = l2.y, mono = l2.z;
    if (haze != 0.0) {
        float h = haze * 0.12;
        c = max((c - h) / (1.0 - h), float3(0.0));
        if (haze > 0.0) { float y = lum(c); c = mix(float3(y), c, 1.0 + haze * 0.25); }
    }
    if (mono > 0.5) c = float3(dot(c, float3(0.82, 0.18, 0.0)));
    {
        float y = lum(c), ny = y + sh * 0.6 * y * (1.0 - y) * (1.0 - y) - hi * 0.6 * y * y * (1.0 - y);
        c *= max(ny, 0.0) / max(y, 0.0001);
    }
    c = clamp(c, 0.0, 1.0);
    if (con > 0.0) c = mix(c, c * c * (3.0 - 2.0 * c), con);
    else c = (c - 0.5) * (1.0 + con * 0.5) + 0.5;
    if (mono < 0.5) {
        float bl = clamp((c.b - max(c.r, c.g * 0.88)) * 5.0, 0.0, 1.0);
        if (cpl != 0.0) {
            float y = lum(c);
            float3 dd = mix(float3(y), c, 1.0 + 0.6 * cpl) * (1.0 - 0.32 * cpl);
            c = mix(c, dd, bl);
        }
        float sat = mx3(c) - min(c.r, min(c.g, c.b));
        c = mix(float3(lum(c)), c, 1.0 + vib * (1.0 - sat) * 0.9);
    }
    c = clamp(c, 0.0, 1.0);
    return float4(pow(c, float3(2.2)), 1.0);
}

}
}
