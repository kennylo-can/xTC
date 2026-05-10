#include "LTCBridge.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct XTCLTCEncoder {
  LTCEncoder *encoder;
  enum LTC_TV_STANDARD standard;
};

static enum LTC_TV_STANDARD sanitize_standard(int tv_standard) {
  switch (tv_standard) {
    case LTC_TV_625_50:
      return LTC_TV_625_50;
    case LTC_TV_1125_60:
      return LTC_TV_1125_60;
    case LTC_TV_FILM_24:
      return LTC_TV_FILM_24;
    case LTC_TV_525_60:
    default:
      return LTC_TV_525_60;
  }
}

XTCLTCEncoder *xtc_ltc_encoder_create(double sample_rate, double fps, int tv_standard, double dbfs, double rise_time_us) {
  enum LTC_TV_STANDARD standard = sanitize_standard(tv_standard);
  LTCEncoder *enc = ltc_encoder_create(sample_rate, fps, standard, 0);
  if (!enc) {
    return NULL;
  }
  ltc_encoder_set_filter(enc, rise_time_us);
  ltc_encoder_set_volume(enc, dbfs);

  XTCLTCEncoder *wrapper = (XTCLTCEncoder *)calloc(1, sizeof(XTCLTCEncoder));
  if (!wrapper) {
    ltc_encoder_free(enc);
    return NULL;
  }
  wrapper->encoder = enc;
  wrapper->standard = standard;
  return wrapper;
}

void xtc_ltc_encoder_free(XTCLTCEncoder *encoder) {
  if (!encoder) {
    return;
  }
  if (encoder->encoder) {
    ltc_encoder_free(encoder->encoder);
    encoder->encoder = NULL;
  }
  free(encoder);
}

int xtc_ltc_encoder_reinit(XTCLTCEncoder *encoder, double sample_rate, double fps, int tv_standard, double dbfs, double rise_time_us) {
  if (!encoder || !encoder->encoder) {
    return -1;
  }
  encoder->standard = sanitize_standard(tv_standard);
  int rc = ltc_encoder_reinit(encoder->encoder, sample_rate, fps, encoder->standard, 0);
  if (rc != 0) {
    return rc;
  }
  ltc_encoder_set_filter(encoder->encoder, rise_time_us);
  ltc_encoder_set_volume(encoder->encoder, dbfs);
  ltc_encoder_buffer_flush(encoder->encoder);
  return 0;
}

int xtc_ltc_encoder_encode_frame(
  XTCLTCEncoder *encoder,
  int hours,
  int minutes,
  int seconds,
  int frames,
  int drop_frame,
  float *out_samples,
  int out_capacity
) {
  if (!encoder || !encoder->encoder || !out_samples || out_capacity <= 0) {
    return -1;
  }

  SMPTETimecode tc;
  memset(&tc, 0, sizeof(tc));
  tc.hours = (unsigned char)(hours & 0xff);
  tc.mins = (unsigned char)(minutes & 0xff);
  tc.secs = (unsigned char)(seconds & 0xff);
  tc.frame = (unsigned char)(frames & 0xff);

  ltc_encoder_set_timecode(encoder->encoder, &tc);

  // Apply DF bit explicitly per frame and refresh parity for this standard.
  LTCFrame frame;
  ltc_encoder_get_frame(encoder->encoder, &frame);
  frame.dfbit = drop_frame ? 1 : 0;
  ltc_frame_set_parity(&frame, encoder->standard);
  ltc_encoder_set_frame(encoder->encoder, &frame);

  ltc_encoder_buffer_flush(encoder->encoder);
  ltc_encoder_encode_frame(encoder->encoder);

  int encoded_len = 0;
  ltcsnd_sample_t *encoded = ltc_encoder_get_bufptr(encoder->encoder, &encoded_len, 1);
  if (!encoded || encoded_len <= 0) {
    return 0;
  }

  if (encoded_len > out_capacity) {
    encoded_len = out_capacity;
  }

  for (int i = 0; i < encoded_len; ++i) {
    out_samples[i] = (((float)encoded[i]) - 128.0f) / 127.0f;
  }
  return encoded_len;
}
