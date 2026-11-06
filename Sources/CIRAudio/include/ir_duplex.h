#ifndef IR_DUPLEX_H
#define IR_DUPLEX_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

/// Sample-aligned play + record on one Core Audio device, from a single IOProc.
/// Input and output of each cycle share the device clock, so the round-trip latency is constant
/// for the whole run and the recording lines up with the playback buffer.
typedef struct IRDuplex IRDuplex;

IRDuplex *ird_create(AudioObjectID device);
void ird_destroy(IRDuplex *d);

/// Starts the IOProc.
/// - play: mono buffer, peak 1.0 (not copied: keep it alive until ird_stop). May be NULL for silence.
/// - loop: repeat `play` until stopped (level check), otherwise play once.
/// - outMask: bit n set = send to output channel n (0-based, across all output streams).
/// - rec: destination for `recFrames` samples of input channel `inChannel`, or NULL to only meter.
/// - gain: linear output gain; changes are smoothed (~5 ms).
OSStatus ird_start(IRDuplex *d, const float *play, int64_t playFrames, bool loop, uint64_t outMask,
                   float *rec, int64_t recFrames, int inChannel, float gain);
void ird_set_gain(IRDuplex *d, float gain);
/// Ramps the output to silence and ends the run (safe from any thread). The run is marked aborted.
void ird_request_stop(IRDuplex *d);
/// Stops and removes the IOProc. Call from a normal thread after the run is done or aborted.
void ird_stop(IRDuplex *d);

bool ird_is_done(IRDuplex *d);
bool ird_was_aborted(IRDuplex *d);
int64_t ird_rec_position(IRDuplex *d);
/// Peak |sample| since the last call, then resets it.
float ird_take_in_peak(IRDuplex *d);
float ird_take_out_peak(IRDuplex *d);
/// Number of output / input channels seen in the last cycle.
int ird_output_channels(IRDuplex *d);
int ird_input_channels(IRDuplex *d);

#endif
