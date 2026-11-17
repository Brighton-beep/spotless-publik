// C surface of ios/spike-audio (Rust staticlib). Strings returned are owned by Rust:
// free them with spike_string_free.
#pragma once
#include <stdbool.h>
#include <stdint.h>

// Runs every self-test (ao=pcm to files, no speakers) and returns a JSON report.
// fixtures: dir holding a.wav and b.wav. work: writable dir. url: googlevideo URL or NULL.
char *spike_selftest(const char *fixtures, const char *work, const char *url);

// Starts continuous playback of src on output `ao` ("audiounit", "null", ...) at mpv volume
// 0-100. A local file loops forever. Returns false (and logs) on failure.
bool spike_live_start(const char *src, const char *ao, const char *cache, int64_t volume);
// Playback position in seconds, -1 when nothing is playing.
double spike_live_position(void);
// The AO mpv actually opened ("current-ao"), or "" if none. Free with spike_string_free.
char *spike_live_ao(void);
void spike_live_stop(void);
void spike_string_free(char *s);
