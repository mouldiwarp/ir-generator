#include "ir_duplex.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct IRDuplex {
    AudioObjectID device;
    AudioDeviceIOProcID proc;
    bool running;

    const float *play;
    int64_t playFrames, playPos;
    bool loop;
    uint64_t outMask;

    float *rec;
    int64_t recFrames;
    _Atomic int64_t recPos;
    int inChannel;

    _Atomic float targetGain;
    float gain, smooth;
    _Atomic bool stopRequested;
    _Atomic bool done;
    _Atomic bool aborted;

    _Atomic uint32_t inPeak, outPeak;     // float bit patterns
    _Atomic int outChannels, inChannels;
};

static inline uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float bitsf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static void peak_max(_Atomic uint32_t *slot, float v) {
    uint32_t cur = atomic_load_explicit(slot, memory_order_relaxed);
    while (v > bitsf(cur) &&
           !atomic_compare_exchange_weak_explicit(slot, &cur, fbits(v), memory_order_relaxed, memory_order_relaxed)) {}
}

static OSStatus ioproc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in,
                       const AudioTimeStamp *inTime, AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    (void)dev; (void)now; (void)inTime; (void)outTime;
    IRDuplex *d = ctx;
    bool finished = atomic_load_explicit(&d->done, memory_order_acquire);

    // ---- Input: record one channel, meter it.
    if (in) {
        int chBase = 0, total = 0;
        for (UInt32 b = 0; b < in->mNumberBuffers; b++) total += (int)in->mBuffers[b].mNumberChannels;
        atomic_store_explicit(&d->inChannels, total, memory_order_relaxed);
        for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
            const AudioBuffer *buf = &in->mBuffers[b];
            int nch = (int)buf->mNumberChannels;
            if (d->inChannel >= chBase && d->inChannel < chBase + nch && buf->mData && nch > 0) {
                const float *src = buf->mData;
                int c = d->inChannel - chBase;
                int64_t frames = buf->mDataByteSize / (sizeof(float) * (UInt32)nch);
                int64_t pos = atomic_load_explicit(&d->recPos, memory_order_relaxed);
                float pk = 0;
                for (int64_t i = 0; i < frames; i++) {
                    float v = src[i * nch + c];
                    float a = fabsf(v);
                    if (a > pk) pk = a;
                    if (!finished && d->rec && pos < d->recFrames) d->rec[pos++] = v;
                }
                atomic_store_explicit(&d->recPos, pos, memory_order_release);
                peak_max(&d->inPeak, pk);
            }
            chBase += nch;
        }
    }

    // ---- Output: silence everywhere, then the test signal on the selected channels.
    if (out) {
        int total = 0;
        for (UInt32 b = 0; b < out->mNumberBuffers; b++) total += (int)out->mBuffers[b].mNumberChannels;
        atomic_store_explicit(&d->outChannels, total, memory_order_relaxed);
        int64_t frames = 0;
        for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
            AudioBuffer *buf = &out->mBuffers[b];
            if (buf->mData) memset(buf->mData, 0, buf->mDataByteSize);
            if (buf->mNumberChannels > 0) {
                int64_t f = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
                if (f > frames) frames = f;
            }
        }
        bool stopReq = atomic_load_explicit(&d->stopRequested, memory_order_acquire);
        float target = stopReq ? 0.0f : atomic_load_explicit(&d->targetGain, memory_order_relaxed);
        float pk = 0;
        for (int64_t i = 0; i < frames && !finished; i++) {
            d->gain += (target - d->gain) * d->smooth;
            float s = 0;
            if (d->play && d->playPos < d->playFrames) {
                s = d->play[d->playPos] * d->gain;
                d->playPos++;
                if (d->loop && d->playPos >= d->playFrames) d->playPos = 0;
            }
            float a = fabsf(s);
            if (a > pk) pk = a;
            int chBase = 0;
            for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
                AudioBuffer *buf = &out->mBuffers[b];
                int nch = (int)buf->mNumberChannels;
                float *dst = buf->mData;
                int64_t bf = nch > 0 ? buf->mDataByteSize / (sizeof(float) * (UInt32)nch) : 0;
                if (dst && i < bf) {
                    for (int c = 0; c < nch; c++) {
                        int ch = chBase + c;
                        if (ch < 64 && (d->outMask >> ch) & 1) dst[i * nch + c] = s;
                    }
                }
                chBase += nch;
            }
        }
        peak_max(&d->outPeak, pk);

        // End of run: a stop request once the ramp is silent, or a one-shot run once both buffers are full.
        if (!finished) {
            if (stopReq && d->gain < 1e-5f) {
                atomic_store_explicit(&d->aborted, true, memory_order_relaxed);
                atomic_store_explicit(&d->done, true, memory_order_release);
            } else if (!d->loop) {
                bool playDone = !d->play || d->playPos >= d->playFrames;
                bool recDone = !d->rec || atomic_load_explicit(&d->recPos, memory_order_relaxed) >= d->recFrames;
                if (playDone && recDone) atomic_store_explicit(&d->done, true, memory_order_release);
            }
        }
    }
    return noErr;
}

IRDuplex *ird_create(AudioObjectID device) {
    IRDuplex *d = calloc(1, sizeof(IRDuplex));
    d->device = device;
    return d;
}

void ird_destroy(IRDuplex *d) {
    if (!d) return;
    ird_stop(d);
    free(d);
}

OSStatus ird_start(IRDuplex *d, const float *play, int64_t playFrames, bool loop, uint64_t outMask,
                   float *rec, int64_t recFrames, int inChannel, float gain) {
    ird_stop(d);
    d->play = play; d->playFrames = play ? playFrames : 0; d->playPos = 0; d->loop = loop;
    d->outMask = outMask;
    d->rec = rec; d->recFrames = rec ? recFrames : 0; d->inChannel = inChannel;
    atomic_store(&d->recPos, 0);
    atomic_store(&d->targetGain, gain);
    d->gain = 0;                      // always ramp in
    Float64 rate = 48000;
    UInt32 size = sizeof(rate);
    AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(d->device, &a, 0, NULL, &size, &rate);
    d->smooth = 1.0f - expf(-1.0f / (0.005f * (float)rate));
    atomic_store(&d->stopRequested, false);
    atomic_store(&d->done, false);
    atomic_store(&d->aborted, false);
    atomic_store(&d->inPeak, 0); atomic_store(&d->outPeak, 0);

    OSStatus st = AudioDeviceCreateIOProcID(d->device, ioproc, d, &d->proc);
    if (st != noErr) return st;
    st = AudioDeviceStart(d->device, d->proc);
    if (st != noErr) {
        AudioDeviceDestroyIOProcID(d->device, d->proc);
        d->proc = NULL;
        return st;
    }
    d->running = true;
    return noErr;
}

void ird_set_gain(IRDuplex *d, float gain) { atomic_store(&d->targetGain, gain); }
void ird_request_stop(IRDuplex *d) { atomic_store(&d->stopRequested, true); }

void ird_stop(IRDuplex *d) {
    if (!d->running) return;
    AudioDeviceStop(d->device, d->proc);
    AudioDeviceDestroyIOProcID(d->device, d->proc);
    d->proc = NULL;
    d->running = false;
}

bool ird_is_done(IRDuplex *d) { return atomic_load(&d->done); }
bool ird_was_aborted(IRDuplex *d) { return atomic_load(&d->aborted); }
int64_t ird_rec_position(IRDuplex *d) { return atomic_load(&d->recPos); }
float ird_take_in_peak(IRDuplex *d) { return bitsf(atomic_exchange(&d->inPeak, 0)); }
float ird_take_out_peak(IRDuplex *d) { return bitsf(atomic_exchange(&d->outPeak, 0)); }
int ird_output_channels(IRDuplex *d) { return atomic_load(&d->outChannels); }
int ird_input_channels(IRDuplex *d) { return atomic_load(&d->inChannels); }
