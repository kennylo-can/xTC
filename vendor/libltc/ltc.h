#ifndef TC_CONVERSION_LTC_H
#define TC_CONVERSION_LTC_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>

typedef unsigned char ltcsnd_sample_t;
typedef long long int ltc_off_t;

#define LTC_FRAME_BIT_COUNT 80
#define SAMPLE_CENTER 128

typedef struct LTCFrame {
  unsigned char data[10];
} LTCFrame;

typedef struct LTCFrameExt {
  LTCFrame ltc;
  ltc_off_t off_start;
  ltc_off_t off_end;
  int reverse;
  float biphase_tics[LTC_FRAME_BIT_COUNT];
  ltcsnd_sample_t sample_min;
  ltcsnd_sample_t sample_max;
  double volume;
} LTCFrameExt;

struct LTCDecoder;
typedef struct LTCDecoder *LTCDecoderRef;

LTCDecoderRef ltc_decoder_create(int apv, int queue_len);
int ltc_decoder_free(LTCDecoderRef d);
void ltc_decoder_write_float(LTCDecoderRef d, float *buf, size_t size, ltc_off_t posinfo);
int ltc_decoder_read(LTCDecoderRef d, LTCFrameExt *frame);
void ltc_decoder_queue_flush(LTCDecoderRef d);
int ltc_decoder_queue_length(LTCDecoderRef d);

#ifdef __cplusplus
}
#endif

#endif
