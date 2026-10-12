Fix stale `IN` readiness of `TimerfdFile` after `set_time` and `read`

`TimerfdFile::set_time` and `TimerfdFile::try_read` reset the expiration
counter but left the `Pollee`'s cached readiness untouched, so `epoll_wait`
kept reporting a disarmed or drained timerfd as readable. ERTS arms a
timerfd before every `epoll_wait` and disarms it afterwards without
reading it; on Asterinas its poll thread therefore spun at 100%.

Invalidate the pollee wherever the counter is reset, so that the cached
readiness stays consistent with `check_io_events`. Add a regression test
that covers disarming, reading and rearming.
