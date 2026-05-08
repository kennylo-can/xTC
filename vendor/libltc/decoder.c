#include "decoder.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define HEX__(n) 0x##n##LU
#define B8__(x) ((x&0x0000000FLU)?1:0) \
	+((x&0x000000F0LU)?2:0) \
	+((x&0x00000F00LU)?4:0) \
	+((x&0x0000F000LU)?8:0) \
	+((x&0x000F0000LU)?16:0) \
	+((x&0x00F00000LU)?32:0) \
	+((x&0x0F000000LU)?64:0) \
	+((x&0xF0000000LU)?128:0)
#define B8(d) ((unsigned char)B8__(HEX__(d)))
#define B16(dmsb,dlsb) (((unsigned short)B8(dmsb)<<8) + B8(dlsb))

static double calc_volume_db(LTCDecoderRef d) {
  if (d->snd_to_biphase_max <= d->snd_to_biphase_min) {
    return -INFINITY;
  }
  return 20.0 * log10((d->snd_to_biphase_max - d->snd_to_biphase_min) / 255.0);
}

static void parse_ltc(LTCDecoderRef d, unsigned char bit, ltc_off_t offset, ltc_off_t posinfo) {
  if (d->bit_cnt == 0) {
    memset(&d->ltc_frame, 0, sizeof(LTCFrame));
    if (d->frame_start_prev < 0) {
      d->frame_start_off = posinfo - d->snd_to_biphase_period;
    } else {
      d->frame_start_off = d->frame_start_prev;
    }
  }
  d->frame_start_prev = offset + posinfo;

  if (d->bit_cnt >= LTC_FRAME_BIT_COUNT) {
    int k;
    const int byte_num_max = LTC_FRAME_BIT_COUNT >> 3;
    for (k = 0; k < byte_num_max; k++) {
      const unsigned char bi = ((unsigned char *)&d->ltc_frame)[k];
      unsigned char bo = 0;
      bo |= (bi & B8(10000000)) ? B8(01000000) : 0;
      bo |= (bi & B8(01000000)) ? B8(00100000) : 0;
      bo |= (bi & B8(00100000)) ? B8(00010000) : 0;
      bo |= (bi & B8(00010000)) ? B8(00001000) : 0;
      bo |= (bi & B8(00001000)) ? B8(00000100) : 0;
      bo |= (bi & B8(00000100)) ? B8(00000010) : 0;
      bo |= (bi & B8(00000010)) ? B8(00000001) : 0;
      if (k + 1 < byte_num_max) {
        bo |= ((((unsigned char *)&d->ltc_frame)[k + 1]) & B8(00000001)) ? B8(10000000) : B8(00000000);
      }
      ((unsigned char *)&d->ltc_frame)[k] = bo;
    }

    d->frame_start_off += ceil(d->snd_to_biphase_period);
    d->bit_cnt--;
  }

  d->decoder_sync_word <<= 1;
  if (bit) {
    d->decoder_sync_word |= B16(00000000,00000001);

    if (d->bit_cnt < LTC_FRAME_BIT_COUNT) {
      const int bit_num = (d->bit_cnt & B8(00000111));
      const int bit_set = (B8(00000001) << bit_num);
      const int byte_num = d->bit_cnt >> 3;
      ((unsigned char *)&d->ltc_frame)[byte_num] |= bit_set;
    }
  }
  d->bit_cnt++;

  if (d->decoder_sync_word == B16(00111111,11111101)) {
    if (d->bit_cnt == LTC_FRAME_BIT_COUNT) {
      int bc;
      if (d->queue_write_off == d->queue_len) {
        d->queue_write_off = 0;
      }
      memcpy(&d->queue[d->queue_write_off].ltc, &d->ltc_frame, sizeof(LTCFrame));
      for (bc = 0; bc < LTC_FRAME_BIT_COUNT; ++bc) {
        const int btc = (d->biphase_tic + bc) % LTC_FRAME_BIT_COUNT;
        d->queue[d->queue_write_off].biphase_tics[bc] = d->biphase_tics[btc];
      }
      d->queue[d->queue_write_off].off_start = d->frame_start_off;
      d->queue[d->queue_write_off].off_end = posinfo + (ltc_off_t)offset - 1LL;
      d->queue[d->queue_write_off].reverse = 0;
      d->queue[d->queue_write_off].volume = calc_volume_db(d);
      d->queue[d->queue_write_off].sample_min = d->snd_to_biphase_min;
      d->queue[d->queue_write_off].sample_max = d->snd_to_biphase_max;
      d->queue_write_off++;
    }
    d->bit_cnt = 0;
  }

  if (d->decoder_sync_word == B16(10111111,11111100)) {
    if (d->bit_cnt == LTC_FRAME_BIT_COUNT) {
      int bc;
      int k;
      int byte_num_max = LTC_FRAME_BIT_COUNT >> 3;
      for (k = 0; k < byte_num_max; k++) {
        const unsigned char bi = ((unsigned char *)&d->ltc_frame)[k];
        unsigned char bo = 0;
        bo |= (bi & B8(10000000)) ? B8(00000001) : 0;
        bo |= (bi & B8(01000000)) ? B8(00000010) : 0;
        bo |= (bi & B8(00100000)) ? B8(00000100) : 0;
        bo |= (bi & B8(00010000)) ? B8(00001000) : 0;
        bo |= (bi & B8(00001000)) ? B8(00010000) : 0;
        bo |= (bi & B8(00000100)) ? B8(00100000) : 0;
        bo |= (bi & B8(00000010)) ? B8(01000000) : 0;
        bo |= (bi & B8(00000001)) ? B8(10000000) : 0;
        ((unsigned char *)&d->ltc_frame)[k] = bo;
      }

      byte_num_max -= 2;
      for (k = 0; k < (byte_num_max) / 2; k++) {
        const unsigned char bi = ((unsigned char *)&d->ltc_frame)[k];
        ((unsigned char *)&d->ltc_frame)[k] = ((unsigned char *)&d->ltc_frame)[byte_num_max - 1 - k];
        ((unsigned char *)&d->ltc_frame)[byte_num_max - 1 - k] = bi;
      }

      if (d->queue_write_off == d->queue_len) {
        d->queue_write_off = 0;
      }
      memcpy(&d->queue[d->queue_write_off].ltc, &d->ltc_frame, sizeof(LTCFrame));
      for (bc = 0; bc < LTC_FRAME_BIT_COUNT; ++bc) {
        const int btc = (d->biphase_tic + bc) % LTC_FRAME_BIT_COUNT;
        d->queue[d->queue_write_off].biphase_tics[bc] = d->biphase_tics[btc];
      }
      d->queue[d->queue_write_off].off_start = d->frame_start_off - 16 * d->snd_to_biphase_period;
      d->queue[d->queue_write_off].off_end = posinfo + (ltc_off_t)offset - 1LL - 16 * d->snd_to_biphase_period;
      d->queue[d->queue_write_off].reverse = (LTC_FRAME_BIT_COUNT >> 3) * 8 * d->snd_to_biphase_period;
      d->queue[d->queue_write_off].volume = calc_volume_db(d);
      d->queue[d->queue_write_off].sample_min = d->snd_to_biphase_min;
      d->queue[d->queue_write_off].sample_max = d->snd_to_biphase_max;
      d->queue_write_off++;
    }
    d->bit_cnt = 0;
  }
}

static inline void biphase_decode2(LTCDecoderRef d, ltc_off_t offset, ltc_off_t pos) {
  d->biphase_tics[d->biphase_tic] = d->snd_to_biphase_period;
  d->biphase_tic = (d->biphase_tic + 1) % LTC_FRAME_BIT_COUNT;
  if (d->snd_to_biphase_cnt <= 2 * d->snd_to_biphase_period) {
    pos -= (d->snd_to_biphase_period - d->snd_to_biphase_cnt);
  }

  if (d->snd_to_biphase_state == d->biphase_prev) {
    d->biphase_state = 1;
    parse_ltc(d, 0, offset, pos);
  } else {
    d->biphase_state = 1 - d->biphase_state;
    if (d->biphase_state == 1) {
      parse_ltc(d, 1, offset, pos);
    }
  }
  d->biphase_prev = d->snd_to_biphase_state;
}

void decode_ltc(LTCDecoderRef d, ltcsnd_sample_t *sound, size_t size, ltc_off_t posinfo) {
  for (size_t i = 0; i < size; i++) {
    ltcsnd_sample_t max_threshold, min_threshold;

    d->snd_to_biphase_min = SAMPLE_CENTER - (((SAMPLE_CENTER - d->snd_to_biphase_min) * 15) / 16);
    d->snd_to_biphase_max = SAMPLE_CENTER + (((d->snd_to_biphase_max - SAMPLE_CENTER) * 15) / 16);

    if (sound[i] < d->snd_to_biphase_min) {
      d->snd_to_biphase_min = sound[i];
    }
    if (sound[i] > d->snd_to_biphase_max) {
      d->snd_to_biphase_max = sound[i];
    }

    min_threshold = SAMPLE_CENTER - (((SAMPLE_CENTER - d->snd_to_biphase_min) * 8) / 16);
    max_threshold = SAMPLE_CENTER + (((d->snd_to_biphase_max - SAMPLE_CENTER) * 8) / 16);

    if ((d->snd_to_biphase_state && (sound[i] > max_threshold)) ||
        (!d->snd_to_biphase_state && (sound[i] < min_threshold))) {
      if (d->snd_to_biphase_cnt > d->snd_to_biphase_lmt) {
        biphase_decode2(d, (ltc_off_t)i, posinfo);
        biphase_decode2(d, (ltc_off_t)i, posinfo);
      } else {
        d->snd_to_biphase_cnt *= 2;
        biphase_decode2(d, (ltc_off_t)i, posinfo);
      }

      if (d->snd_to_biphase_cnt > (d->snd_to_biphase_period * 4)) {
        d->bit_cnt = 0;
      } else {
        d->snd_to_biphase_period = (d->snd_to_biphase_period * 3.0 + d->snd_to_biphase_cnt) / 4.0;
        d->snd_to_biphase_lmt = (d->snd_to_biphase_period * 3) / 4;
      }

      d->snd_to_biphase_cnt = 0;
      d->snd_to_biphase_state = !d->snd_to_biphase_state;
    }
    d->snd_to_biphase_cnt++;
  }
}

LTCDecoderRef ltc_decoder_create(int apv, int queue_len) {
  LTCDecoderRef d = (LTCDecoderRef)calloc(1, sizeof(struct LTCDecoder));
  if (!d) {
    return NULL;
  }
  if (queue_len < 1) {
    queue_len = 1;
  }

  d->queue_len = queue_len;
  d->queue = (LTCFrameExt *)calloc((size_t)d->queue_len, sizeof(LTCFrameExt));
  if (!d->queue) {
    free(d);
    return NULL;
  }

  d->biphase_state = 1;
  d->snd_to_biphase_period = apv / 80.0;
  d->snd_to_biphase_lmt = (d->snd_to_biphase_period * 3) / 4;
  d->snd_to_biphase_min = SAMPLE_CENTER;
  d->snd_to_biphase_max = SAMPLE_CENTER;
  d->frame_start_prev = -1;
  d->biphase_tic = 0;

  return d;
}

int ltc_decoder_free(LTCDecoderRef d) {
  if (!d) {
    return 1;
  }
  if (d->queue) {
    free(d->queue);
  }
  free(d);
  return 0;
}

void ltc_decoder_write_float(LTCDecoderRef d, float *buf, size_t size, ltc_off_t posinfo) {
  ltcsnd_sample_t tmp[1024];
  size_t copyStart = 0;
  while (copyStart < size) {
    int c = (int)(size - copyStart);
    if (c > (int)(sizeof(tmp) / sizeof(tmp[0]))) {
      c = (int)(sizeof(tmp) / sizeof(tmp[0]));
    }
    for (int i = 0; i < c; i++) {
      float sample = buf[copyStart + (size_t)i];
      int value = (int)lrintf(128.0f + (sample * 127.0f));
      if (value < 0) value = 0;
      if (value > 255) value = 255;
      tmp[i] = (ltcsnd_sample_t)value;
    }
    decode_ltc(d, tmp, (size_t)c, posinfo + (ltc_off_t)copyStart);
    copyStart += (size_t)c;
  }
}

int ltc_decoder_read(LTCDecoderRef d, LTCFrameExt *frame) {
  if (!frame) {
    return -1;
  }
  if (d->queue_read_off != d->queue_write_off) {
    if (d->queue_read_off == d->queue_len) {
      d->queue_read_off = 0;
    }
    memcpy(frame, &d->queue[d->queue_read_off], sizeof(LTCFrameExt));
    d->queue_read_off++;
    return 1;
  }
  return 0;
}

void ltc_decoder_queue_flush(LTCDecoderRef d) {
  d->queue_read_off = d->queue_write_off;
}

int ltc_decoder_queue_length(LTCDecoderRef d) {
  return (d->queue_write_off - d->queue_read_off + d->queue_len) % d->queue_len;
}
