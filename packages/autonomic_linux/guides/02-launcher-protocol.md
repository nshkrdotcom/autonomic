# Launcher Protocol and Native Integration

The native launcher (`autonomic_launcher`) is an external privileged Rust helper. It is intentionally an external Port daemon rather than an in-process BEAM NIF to ensure any fault or container crash does not threaten the BEAM VM.

## Port Communication

- Framed JSON over standard input/output (`:stream`, 4-byte length prefixed).
- Actions: `daemon`, `worker-init`, `worker-exec`, `worker-kill`, `status`.
- Executable resolution checks:
  1. `AUTONOMIC_LAUNCHER` environment variable.
  2. `:autonomic_linux, :executable` application environment.
  3. `priv/autonomic_launcher` inside the package.
  4. System fallback: `/usr/local/libexec/autonomic_launcher`.
