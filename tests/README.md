# tests

Cross-cutting tests. Unit tests live next to each service in `services/<name>/tests` and run in
the image's `test` stage (`make test`).

- `smoke/` — end-to-end and `kubectl auth can-i` checks against the cluster (Phase 1–2)
- `promtool/` — `promtool test rules` unit tests, one per alert (Phase 3)
