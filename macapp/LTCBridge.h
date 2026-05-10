#include "../vendor/libltc/ltc.h"

// Backward-compatible alias for existing Swift decode code.
typedef LTCDecoder *LTCDecoderRef;

// Thin C bridge around libltc encoder for Swift.
typedef struct XTCLTCEncoder XTCLTCEncoder;

XTCLTCEncoder *xtc_ltc_encoder_create(double sample_rate, double fps, int tv_standard, double dbfs, double rise_time_us);
void xtc_ltc_encoder_free(XTCLTCEncoder *encoder);
int xtc_ltc_encoder_reinit(XTCLTCEncoder *encoder, double sample_rate, double fps, int tv_standard, double dbfs, double rise_time_us);
int xtc_ltc_encoder_encode_frame(
  XTCLTCEncoder *encoder,
  int hours,
  int minutes,
  int seconds,
  int frames,
  int drop_frame,
  float *out_samples,
  int out_capacity
);
