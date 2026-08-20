# External Review Tests

Run the deterministic POSIX contract suite with:

```bash
bash tests/external-review/run-tests.sh
```

The suite uses fake CLIs, so it needs no credentials or network access. The
pre-implementation pressure evidence is in
[pressure-scenarios.md](pressure-scenarios.md).

`indeterminate` is computed only by `status` and `wait`. It is never persisted
over the last reliable state.
