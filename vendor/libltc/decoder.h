#ifndef TC_CONVERSION_DECODER_H
#define TC_CONVERSION_DECODER_H

#include "ltc.h"

struct LTCDecoder {
  LTCFrameExt *queue;
  int queue_len;
  int queue_read_off;
  int queue_write_off;

  unsigned char biphase_state;
  unsigned char biphase_prev;
  unsigned char snd_to_biphase_state;
  int snd_to_biphase_cnt;
  int snd_to_biphase_lmt;
  double snd_to_biphase_period;

  ltcsnd_sample_t snd_to_biphase_min;
  ltcsnd_sample_t snd_to_biphase_max;

  unsigned short decoder_sync_word;
  LTCFrame ltc_frame;
  int bit_cnt;

  ltc_off_t frame_start_off;
  ltc_off_t frame_start_prev;

  float biphase_tics[LTC_FRAME_BIT_COUNT];
  int biphase_tic;
};

void decode_ltc(LTCDecoderRef d, ltcsnd_sample_t *sound, size_t size, ltc_off_t posinfo);

#endif
