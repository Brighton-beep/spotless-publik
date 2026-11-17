## Spotless 1.0.2

- More reliable playback: when YouTube asks for a check, Spotless now refreshes its anonymous session and retries once instead of failing.
- No more runaway skipping: a temporary refusal never marks songs as unavailable, and after three failures in a row playback stops with a clear message.
- Spotless backs off politely when YouTube is busy, and looks ahead less aggressively on iPhone.
