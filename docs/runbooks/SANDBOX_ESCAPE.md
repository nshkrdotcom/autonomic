# Runbook: suspected sandbox escape

1. Do not investigate from inside the suspect worker.
2. If PostgreSQL is healthy, advance the episode epoch to invalidate old leases/effects.
3. Freeze then cgroup-kill the entire old domain; require an empty-cgroup proof.
4. Quarantine old root/upper/checkpoint material; do not reuse a tainted upperdir.
5. Preserve launcher/kernel/audit evidence and host journal data.
6. Rotate target/broker credentials that could have been exposed by host compromise.
7. Rebuild the launcher/rootfs from a trusted source and rerun every Linux/security acceptance gate before restoring service.
