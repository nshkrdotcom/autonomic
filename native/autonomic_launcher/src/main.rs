use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const PROTOCOL: u64 = 1;
const MAX_REQUEST: usize = 1_048_576;
const MAX_RESPONSE: usize = 4_194_304;
const MAX_OUTPUT: usize = 262_144;

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Domain {
    domain_id: String,
    episode_id: String,
    epoch: u64,
    generation: u64,
    keeper_pid: u32,
    cgroup: PathBuf,
    domain_dir: PathBuf,
    root: PathBuf,
    upper: PathBuf,
    work: PathBuf,
    rootfs: PathBuf,
    workspace_lower: PathBuf,
    effect_socket: PathBuf,
    resource_limits: Value,
    git_base_ref: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct ExecRequest {
    argv: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
}

fn main() {
    let mut args = env::args();
    let _program = args.next();
    match args.next().as_deref() {
        Some("daemon") => {
            if let Err(error) = daemon() {
                eprintln!("launcher daemon fatal: {error}");
                std::process::exit(1);
            }
        }
        Some("worker-init") => {
            let rest: Vec<String> = args.collect();
            if let Err(error) = worker_init(&rest) {
                eprintln!("worker-init fatal: {error}");
                std::process::exit(125);
            }
        }
        Some("worker-exec") => {
            let rest: Vec<String> = args.collect();
            if let Err(error) = worker_exec(&rest) {
                eprintln!("worker-exec fatal: {error}");
                std::process::exit(126);
            }
        }
        _ => {
            eprintln!("usage: autonomic_launcher daemon | worker-init ... | worker-exec ...");
            std::process::exit(2);
        }
    }
}

fn daemon() -> Result<(), String> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("launcher daemon must run as root".into());
    }

    let mut domains: HashMap<String, Domain> = HashMap::new();
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut input = stdin.lock();
    let mut output = stdout.lock();

    loop {
        let payload = match read_frame(&mut input) {
            Ok(Some(payload)) => payload,
            Ok(None) => return Ok(()),
            Err(error) => return Err(error),
        };

        let request: Value = match serde_json::from_slice(&payload) {
            Ok(value) => value,
            Err(error) => {
                write_frame(
                    &mut output,
                    &json!({"request_id": null, "ok": false, "error": format!("invalid json: {error}")}),
                )?;
                continue;
            }
        };

        let request_id = request
            .get("request_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let response = match handle_request(&request, &mut domains) {
            Ok(result) => json!({"request_id": request_id, "ok": true, "result": result}),
            Err(error) => json!({"request_id": request_id, "ok": false, "error": error}),
        };
        write_frame(&mut output, &response)?;
    }
}

fn handle_request(request: &Value, domains: &mut HashMap<String, Domain>) -> Result<Value, String> {
    let object = request.as_object().ok_or("request must be an object")?;
    let protocol = object
        .get("protocol")
        .and_then(Value::as_u64)
        .ok_or("protocol missing")?;
    if protocol != PROTOCOL {
        return Err("unsupported protocol version".into());
    }
    let request_id = string(object, "request_id")?;
    if request_id.len() != 32 || !request_id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid request_id".into());
    }
    let action = string(object, "action")?;
    reject_unknown(object, allowed_fields(action)?)?;

    if !matches!(action, "create_domain" | "restore_domain") {
        ensure_loaded_domain(object, domains)?;
    }

    match action {
        "create_domain" => create_domain(object, domains, None),
        "restore_domain" => restore_domain(object, domains),
        "exec" => exec_domain(object, domains),
        "signal" => signal_domain(object, domains),
        "freeze" => freeze_domain(object, domains, true),
        "thaw" => freeze_domain(object, domains, false),
        "checkpoint_fs" => checkpoint_domain(object, domains),
        "inspect_domain" => inspect_domain(object, domains),
        "destroy_domain" => destroy_domain(object, domains),
        _ => Err("unknown action".into()),
    }
}

fn allowed_fields(action: &str) -> Result<HashSet<&'static str>, String> {
    let base = ["protocol", "request_id", "action"];
    let extra: &[&str] = match action {
        "create_domain" => &[
            "episode_id",
            "epoch",
            "workspace",
            "hard_envelope",
            "resource_limits",
            "environment",
            "effect_socket",
            "rootfs",
            "state_root",
        ],
        "restore_domain" => &[
            "episode_id",
            "epoch",
            "checkpoint_ref",
            "checkpoint_digest",
            "rootfs",
            "workspace_lower",
            "state_root",
            "effect_socket",
            "resource_limits",
        ],
        "exec" => &[
            "domain_id",
            "episode_id",
            "epoch",
            "argv",
            "cwd",
            "env",
            "stdin_b64",
            "timeout_ms",
            "state_root",
        ],
        "signal" => &["domain_id", "episode_id", "epoch", "signal", "state_root"],
        "freeze" | "thaw" | "checkpoint_fs" | "inspect_domain" | "destroy_domain" => {
            &["domain_id", "episode_id", "epoch", "state_root"]
        }
        _ => return Err("unknown action".into()),
    };
    Ok(base.into_iter().chain(extra.iter().copied()).collect())
}

fn reject_unknown(object: &Map<String, Value>, allowed: HashSet<&str>) -> Result<(), String> {
    let unknown: Vec<&String> = object
        .keys()
        .filter(|key| !allowed.contains(key.as_str()))
        .collect();
    if unknown.is_empty() {
        Ok(())
    } else {
        Err(format!("unknown request fields: {unknown:?}"))
    }
}

fn create_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
    restored_upper: Option<&Path>,
) -> Result<Value, String> {
    let episode = string(object, "episode_id")?;
    validate_hex_id(episode, 32, "episode_id")?;
    let epoch = integer(object, "epoch")?;
    if epoch == 0 {
        return Err("epoch must be positive".into());
    }

    let rootfs = canonical_dir(Path::new(string(object, "rootfs")?))?;
    let state_root = secure_absolute(Path::new(string(object, "state_root")?))?;
    fs::create_dir_all(&state_root).map_err(io_error)?;
    std::os::unix::fs::chown(&state_root, Some(0), Some(0)).map_err(io_error)?;
    ensure_directory_mode(&state_root, 0o700)?;

    let workspace = object
        .get("workspace")
        .and_then(Value::as_object)
        .ok_or("workspace missing")?;
    let lower_raw = workspace
        .get("lower")
        .or_else(|| workspace.get("path"))
        .and_then(Value::as_str)
        .ok_or("workspace.lower/path missing")?;
    let workspace_lower = canonical_dir(Path::new(lower_raw))?;
    let git_base_ref = workspace
        .get("base_ref")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let effect_socket = canonical_socket(Path::new(string(object, "effect_socket")?))?;
    let limits = object
        .get("resource_limits")
        .cloned()
        .unwrap_or_else(|| json!({}));

    create_domain_common(
        episode,
        epoch,
        rootfs,
        state_root,
        workspace_lower,
        effect_socket,
        limits,
        git_base_ref,
        domains,
        restored_upper,
    )
}

#[allow(clippy::too_many_arguments)]
fn create_domain_common(
    episode: &str,
    epoch: u64,
    rootfs: PathBuf,
    state_root: PathBuf,
    workspace_lower: PathBuf,
    effect_socket: PathBuf,
    limits: Value,
    git_base_ref: Option<String>,
    domains: &mut HashMap<String, Domain>,
    restored_upper: Option<&Path>,
) -> Result<Value, String> {
    let generation = next_generation(&state_root, episode, epoch)?;
    let nonce = format!(
        "{episode}:{epoch}:{generation}:{}:{}",
        now_ms(),
        std::process::id()
    );
    let domain_id = hex::encode(Sha256::digest(nonce.as_bytes()))[..32].to_owned();
    let domain_dir = state_root
        .join("domains")
        .join(episode)
        .join(format!("epoch-{epoch}"))
        .join(format!("gen-{generation}"));
    let upper = domain_dir.join("upper");
    let work = domain_dir.join("work");
    let root = domain_dir.join("root");
    for dir in [&upper, &work, &root] {
        fs::create_dir_all(dir).map_err(io_error)?;
        ensure_directory_mode(dir, 0o700)?;
    }

    if let Some(snapshot) = restored_upper {
        copy_tree(snapshot, &upper)?;
    }

    let cgroup = cgroup_path(episode, epoch, generation)?;
    configure_cgroup(&cgroup, &limits)?;
    let keeper = spawn_keeper(
        &rootfs,
        &root,
        &workspace_lower,
        &upper,
        &work,
        &effect_socket,
        &cgroup,
    )?;

    let domain = Domain {
        domain_id: domain_id.clone(),
        episode_id: episode.to_owned(),
        epoch,
        generation,
        keeper_pid: keeper,
        cgroup: cgroup.clone(),
        domain_dir: domain_dir.clone(),
        root,
        upper,
        work,
        rootfs,
        workspace_lower: workspace_lower.clone(),
        effect_socket: effect_socket.clone(),
        resource_limits: limits.clone(),
        git_base_ref: git_base_ref.clone(),
    };
    persist_domain(&domain)?;
    domains.insert(domain_id.clone(), domain.clone());

    Ok(json!({
        "domain_id": domain_id,
        "epoch": epoch,
        "generation": generation,
        "keeper_pid": keeper,
        "cgroup": cgroup,
        "workspace_lower": workspace_lower,
        "git_base_ref": git_base_ref,
        "effect_socket": effect_socket,
        "resource_limits": limits
    }))
}

fn restore_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let episode = string(object, "episode_id")?;
    validate_hex_id(episode, 32, "episode_id")?;
    let epoch = integer(object, "epoch")?;
    let checkpoint = canonical_dir(Path::new(string(object, "checkpoint_ref")?))?;
    let expected = string(object, "checkpoint_digest")?;
    let actual = digest_tree(&checkpoint)?;
    if actual != expected {
        return Err("checkpoint digest mismatch".into());
    }
    let rootfs = canonical_dir(Path::new(string(object, "rootfs")?))?;
    let workspace_lower = canonical_dir(Path::new(string(object, "workspace_lower")?))?;
    let state_root = secure_absolute(Path::new(string(object, "state_root")?))?;
    let effect_socket = canonical_socket(Path::new(string(object, "effect_socket")?))?;
    let limits = object
        .get("resource_limits")
        .cloned()
        .unwrap_or_else(|| json!({}));
    create_domain_common(
        episode,
        epoch,
        rootfs,
        state_root,
        workspace_lower,
        effect_socket,
        limits,
        None,
        domains,
        Some(&checkpoint),
    )
}

fn exec_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let domain = checked_domain(object, domains)?.clone();
    let argv = object
        .get("argv")
        .and_then(Value::as_array)
        .ok_or("argv missing")?;
    if argv.is_empty() || argv.len() > 256 {
        return Err("argv count out of bounds".into());
    }
    let argv: Vec<String> = argv
        .iter()
        .map(|v| {
            v.as_str()
                .ok_or("argv must contain strings")
                .map(str::to_owned)
        })
        .collect::<Result<_, _>>()?;
    if argv
        .iter()
        .any(|v| v.as_bytes().contains(&0) || v.len() > 16_384)
    {
        return Err("invalid argv entry".into());
    }
    let cwd = object
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or("/workspace")
        .to_owned();
    if !cwd.starts_with('/') || cwd.contains("\0") {
        return Err("cwd must be absolute".into());
    }
    let env_map = object
        .get("env")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if env_map.len() > 128 {
        return Err("too many environment entries".into());
    }
    let mut environment = HashMap::new();
    for (key, value) in env_map {
        let value = value.as_str().ok_or("environment values must be strings")?;
        validate_env(&key, value)?;
        environment.insert(key, value.to_owned());
    }
    let timeout_ms = object
        .get("timeout_ms")
        .and_then(Value::as_u64)
        .unwrap_or(60_000)
        .clamp(1, 600_000);

    let request = ExecRequest {
        argv,
        cwd,
        env: environment,
    };
    let request_path = domain.domain_dir.join(format!(
        "exec-{}.json",
        hex::encode(Sha256::digest(
            format!("{}:{}", now_ms(), std::process::id()).as_bytes()
        ))[..16]
            .to_owned()
    ));
    write_private_json(&request_path, &request)?;

    let executable = env::current_exe().map_err(io_error)?;
    let mut command = Command::new("/usr/bin/nsenter");
    command
        .args([
            "--target",
            &domain.keeper_pid.to_string(),
            "--mount",
            "--uts",
            "--ipc",
            "--net",
            "--pid",
            "--user",
            "--",
        ])
        .arg(&executable)
        .arg("worker-exec")
        .arg("--root")
        .arg(&domain.root)
        .arg("--request")
        .arg(&request_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    let started = now_ms();
    let cgroup_file = attach_before_exec(&mut command, &domain.cgroup)?;
    let mut child = command
        .spawn()
        .map_err(|e| format!("nsenter spawn failed: {e}"))?;
    drop(cgroup_file);

    if let Some(encoded) = object.get("stdin_b64").and_then(Value::as_str) {
        if encoded.len() > 1_400_000 {
            let _ = child.kill();
            return Err("stdin too large".into());
        }
        // BEAM currently sends standard Base64. A tiny decoder avoids another crate in the launcher.
        let bytes = decode_base64(encoded)?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(&bytes).map_err(io_error)?;
        }
    } else {
        drop(child.stdin.take());
    }

    let stdout = child.stdout.take().ok_or("stdout pipe missing")?;
    let stderr = child.stderr.take().ok_or("stderr pipe missing")?;
    let out_thread = thread::spawn(move || read_limited(stdout, MAX_OUTPUT));
    let err_thread = thread::spawn(move || read_limited(stderr, MAX_OUTPUT));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let status = loop {
        if let Some(status) = child.try_wait().map_err(io_error)? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
            let _ = child.wait();
            let _ = fs::remove_file(&request_path);
            return Err("execution timeout".into());
        }
        thread::sleep(Duration::from_millis(10));
    };
    let (stdout_bytes, stdout_truncated) =
        out_thread.join().map_err(|_| "stdout reader panicked")??;
    let (stderr_bytes, stderr_truncated) =
        err_thread.join().map_err(|_| "stderr reader panicked")??;
    let _ = fs::remove_file(&request_path);

    let termination_signal = status.signal();
    let exit_status = status
        .code()
        .unwrap_or_else(|| 128 + termination_signal.unwrap_or(0));
    let seccomp_violation = termination_signal == Some(libc::SIGSYS);

    Ok(json!({
        "execution_id": hex::encode(Sha256::digest(format!("{}:{}:{}", domain.domain_id, started, child.id()).as_bytes()))[..32].to_owned(),
        "pid": child.id(), "started_at_ms": started, "exit_status": exit_status,
        "termination_signal": termination_signal, "seccomp_violation": seccomp_violation,
        "stdout": String::from_utf8_lossy(&stdout_bytes), "stderr": String::from_utf8_lossy(&stderr_bytes),
        "stdout_truncated": stdout_truncated, "stderr_truncated": stderr_truncated
    }))
}

fn signal_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let domain = checked_domain(object, domains)?;
    let signal = match string(object, "signal")? {
        "sigterm" => libc::SIGTERM,
        "sigkill" => libc::SIGKILL,
        "sigint" => libc::SIGINT,
        "sigtstp" => libc::SIGTSTP,
        "sigcont" => libc::SIGCONT,
        _ => return Err("unsupported signal".into()),
    };
    for pid in cgroup_pids(&domain.cgroup)? {
        unsafe {
            libc::kill(pid as i32, signal);
        }
    }
    Ok(json!({"signaled": true}))
}

fn freeze_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
    freeze: bool,
) -> Result<Value, String> {
    let domain = checked_domain(object, domains)?;
    set_frozen(&domain.cgroup, freeze)?;
    Ok(json!({"frozen": freeze}))
}

fn checkpoint_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let domain = checked_domain(object, domains)?.clone();
    set_frozen(&domain.cgroup, true)?;
    let result = (|| {
        let _ = Command::new("/bin/sync").status();
        let digest = digest_tree(&domain.upper)?;
        let checkpoint = domain
            .domain_dir
            .ancestors()
            .nth(4)
            .unwrap_or(Path::new("/var/lib/autonomic"))
            .join("checkpoints")
            .join(&domain.episode_id)
            .join(&digest);
        if !checkpoint.exists() {
            fs::create_dir_all(&checkpoint).map_err(io_error)?;
            copy_tree(&domain.upper, &checkpoint)?;
        }
        ensure_directory_mode(&checkpoint, 0o700)?;
        Ok(json!({
            "checkpoint_ref": checkpoint, "digest": digest, "workspace_lower": domain.workspace_lower,
            "effect_socket": domain.effect_socket, "resource_limits": domain.resource_limits,
            "environment_digest": digest_strings(&[domain.rootfs.to_string_lossy().as_ref(), domain.workspace_lower.to_string_lossy().as_ref()])
        }))
    })();
    let thaw_result = set_frozen(&domain.cgroup, false);
    match (result, thaw_result) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(e), _) => Err(e),
        (_, Err(e)) => Err(e),
    }
}

fn inspect_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let domain = checked_domain(object, domains)?;
    let events = fs::read_to_string(domain.cgroup.join("cgroup.events")).unwrap_or_default();
    let pids = cgroup_pids(&domain.cgroup).unwrap_or_default();
    Ok(
        json!({"domain_id": domain.domain_id, "epoch": domain.epoch, "generation": domain.generation, "keeper_pid": domain.keeper_pid, "cgroup_events": events, "pids": pids, "populated": !pids.is_empty()}),
    )
}

fn destroy_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<Value, String> {
    let id = string(object, "domain_id")?.to_owned();
    let domain = checked_domain(object, domains)?.clone();
    let pids_before = cgroup_pids(&domain.cgroup).unwrap_or_default();

    if domain.cgroup.join("cgroup.kill").exists() {
        fs::write(domain.cgroup.join("cgroup.kill"), "1\n").map_err(io_error)?;
    } else {
        for pid in &pids_before {
            unsafe {
                libc::kill(*pid as i32, libc::SIGKILL);
            }
        }
    }
    wait_empty(&domain.cgroup, Duration::from_secs(10))?;
    let empty = cgroup_pids(&domain.cgroup)?.is_empty();
    if !empty {
        return Err("cgroup did not become empty".into());
    }

    let mut current = Some(domain.cgroup.as_path());
    while let Some(path) = current {
        if path.ends_with("autonomic") {
            break;
        }
        let _ = fs::remove_dir(path);
        current = path.parent();
    }
    let _ = fs::remove_dir_all(&domain.domain_dir);
    domains.remove(&id);
    Ok(
        json!({"domain_id": id, "empty": true, "killed": pids_before, "cgroup_removed": !domain.cgroup.exists()}),
    )
}

fn ensure_loaded_domain(
    object: &Map<String, Value>,
    domains: &mut HashMap<String, Domain>,
) -> Result<(), String> {
    let id = string(object, "domain_id")?.to_owned();
    if domains.contains_key(&id) {
        return Ok(());
    }

    let episode = string(object, "episode_id")?;
    validate_hex_id(episode, 32, "episode_id")?;
    let epoch = integer(object, "epoch")?;
    let state_root = secure_absolute(Path::new(string(object, "state_root")?))?;
    let epoch_dir = state_root
        .join("domains")
        .join(episode)
        .join(format!("epoch-{epoch}"));
    if !epoch_dir.exists() {
        return Err("domain not found".into());
    }

    for entry in fs::read_dir(&epoch_dir).map_err(io_error)? {
        let path = entry.map_err(io_error)?.path().join("domain.json");
        if !path.is_file() {
            continue;
        }
        let file = File::open(&path).map_err(io_error)?;
        let domain: Domain =
            serde_json::from_reader(file).map_err(|e| format!("invalid persisted domain: {e}"))?;
        if domain.domain_id == id && domain.episode_id == episode && domain.epoch == epoch {
            let expected_cgroup = cgroup_path(episode, epoch, domain.generation)?;
            let expected_prefix = state_root
                .join("domains")
                .join(episode)
                .join(format!("epoch-{epoch}"));
            if domain.cgroup != expected_cgroup || !domain.domain_dir.starts_with(&expected_prefix)
            {
                return Err("persisted domain path validation failed".into());
            }
            domains.insert(id, domain);
            return Ok(());
        }
    }

    Err("domain not found".into())
}

fn checked_domain<'a>(
    object: &Map<String, Value>,
    domains: &'a HashMap<String, Domain>,
) -> Result<&'a Domain, String> {
    let id = string(object, "domain_id")?;
    let domain = domains.get(id).ok_or("domain not found")?;
    if string(object, "episode_id")? != domain.episode_id {
        return Err("episode mismatch".into());
    }
    if integer(object, "epoch")? != domain.epoch {
        return Err("stale epoch".into());
    }
    Ok(domain)
}

fn worker_init(args: &[String]) -> Result<(), String> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("worker-init must be namespace root".into());
    }
    let opts = parse_pairs(args)?;
    let rootfs = canonical_dir(Path::new(required_opt(&opts, "--rootfs")?))?;
    let root = secure_absolute(Path::new(required_opt(&opts, "--root")?))?;
    let lower = canonical_dir(Path::new(required_opt(&opts, "--workspace-lower")?))?;
    let upper = secure_absolute(Path::new(required_opt(&opts, "--upper")?))?;
    let work = secure_absolute(Path::new(required_opt(&opts, "--work")?))?;
    let socket = canonical_socket(Path::new(required_opt(&opts, "--effect-socket")?))?;
    let mut ready = File::create(required_opt(&opts, "--ready")?).map_err(io_error)?;

    run("/usr/bin/mount", &["--make-rprivate", "/"])?;
    run(
        "/usr/bin/mount",
        &["--bind", path_str(&rootfs)?, path_str(&root)?],
    )?;
    run(
        "/usr/bin/mount",
        &["-o", "remount,bind,ro,nosuid,nodev", path_str(&root)?],
    )?;

    let workspace_target = root.join("workspace");
    if !workspace_target.exists() {
        return Err("rootfs must contain /workspace mountpoint".into());
    }
    let overlay_opts = format!(
        "lowerdir={},upperdir={},workdir={}",
        path_str(&lower)?,
        path_str(&upper)?,
        path_str(&work)?
    );
    run_owned(
        "/usr/bin/mount",
        vec![
            "-t".into(),
            "overlay".into(),
            "-o".into(),
            overlay_opts,
            "overlay".into(),
            path_str(&workspace_target)?.into(),
        ],
    )?;

    let run_mount = root.join("run");
    let tmp_mount = root.join("tmp");
    let proc_mount = root.join("proc");
    for path in [&run_mount, &tmp_mount, &proc_mount] {
        if !path.exists() {
            return Err(format!("rootfs missing mountpoint {}", path.display()));
        }
    }
    run(
        "/usr/bin/mount",
        &[
            "-t",
            "tmpfs",
            "-o",
            "size=8m,nosuid,nodev,noexec",
            "tmpfs",
            path_str(&run_mount)?,
        ],
    )?;
    run(
        "/usr/bin/mount",
        &[
            "-t",
            "tmpfs",
            "-o",
            "size=64m,nosuid,nodev",
            "tmpfs",
            path_str(&tmp_mount)?,
        ],
    )?;
    fs::create_dir_all(run_mount.join("autonomic")).map_err(io_error)?;
    let socket_target = run_mount.join("autonomic/effect.sock");
    File::create(&socket_target).map_err(io_error)?;
    run(
        "/usr/bin/mount",
        &["--bind", path_str(&socket)?, path_str(&socket_target)?],
    )?;
    run(
        "/usr/bin/mount",
        &[
            "-t",
            "proc",
            "-o",
            "nosuid,nodev,noexec,hidepid=2",
            "proc",
            path_str(&proc_mount)?,
        ],
    )?;

    let dev_mount = root.join("dev");
    if !dev_mount.is_dir() {
        return Err("rootfs missing /dev mountpoint".into());
    }
    run(
        "/usr/bin/mount",
        &[
            "-t",
            "tmpfs",
            "-o",
            "size=1m,nosuid,noexec,mode=755",
            "tmpfs",
            path_str(&dev_mount)?,
        ],
    )?;
    for name in ["null", "zero", "random", "urandom"] {
        let target = dev_mount.join(name);
        File::create(&target).map_err(io_error)?;
        run_owned(
            "/usr/bin/mount",
            vec![
                "--bind".into(),
                format!("/dev/{name}"),
                path_str(&target)?.into(),
            ],
        )?;
    }

    chroot_to(&root)?;
    env::set_current_dir("/workspace").map_err(io_error)?;
    install_seccomp()?;
    ready.write_all(b"1").map_err(io_error)?;
    drop(ready);
    loop {
        unsafe {
            libc::pause();
        }
    }
}

fn worker_exec(args: &[String]) -> Result<(), String> {
    let opts = parse_pairs(args)?;
    let root = secure_absolute(Path::new(required_opt(&opts, "--root")?))?;
    let request_path = secure_absolute(Path::new(required_opt(&opts, "--request")?))?;
    let file = File::open(&request_path).map_err(io_error)?;
    let request: ExecRequest =
        serde_json::from_reader(file).map_err(|e| format!("invalid exec request: {e}"))?;
    if request.argv.is_empty() {
        return Err("empty argv".into());
    }

    chroot_to(&root)?;
    env::set_current_dir(&request.cwd).map_err(|e| format!("invalid cwd: {e}"))?;
    install_seccomp()?;

    let mut command = Command::new(&request.argv[0]);
    command.args(&request.argv[1..]);
    command.env_clear();
    command.env(
        "PATH",
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    );
    command.env("HOME", "/nonexistent");
    for (key, value) in request.env {
        validate_env(&key, &value)?;
        command.env(key, value);
    }
    let error = command.exec();
    Err(format!("exec failed: {error}"))
}

fn install_seccomp() -> Result<(), String> {
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0 {
        return Err(format!(
            "PR_SET_NO_NEW_PRIVS failed: {}",
            io::Error::last_os_error()
        ));
    }

    const BPF_LD: u16 = 0x00;
    const BPF_W: u16 = 0x00;
    const BPF_ABS: u16 = 0x20;
    const BPF_ALU: u16 = 0x04;
    const BPF_AND: u16 = 0x50;
    const BPF_JMP: u16 = 0x05;
    const BPF_JEQ: u16 = 0x10;
    const BPF_K: u16 = 0x00;
    const BPF_RET: u16 = 0x06;
    const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
    const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;
    const SECCOMP_RET_TRAP: u32 = 0x00030000;
    const SECCOMP_RET_ERRNO: u32 = 0x00050000;
    const EPERM_RET: u32 = SECCOMP_RET_ERRNO | (libc::EPERM as u32);
    const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
    const X32_SYSCALL_BIT: u32 = 0x40000000;

    fn stmt(code: u16, k: u32) -> libc::sock_filter {
        libc::sock_filter {
            code,
            jt: 0,
            jf: 0,
            k,
        }
    }
    fn jump(code: u16, k: u32, jt: u8, jf: u8) -> libc::sock_filter {
        libc::sock_filter { code, jt, jf, k }
    }

    let dangerous: &[i64] = &[
        libc::SYS_mount,
        libc::SYS_fsopen,
        libc::SYS_fsconfig,
        libc::SYS_fsmount,
        libc::SYS_move_mount,
        libc::SYS_open_tree,
        libc::SYS_mount_setattr,
        libc::SYS_chroot,
        libc::SYS_mknod,
        libc::SYS_mknodat,
        libc::SYS_umount2,
        libc::SYS_pivot_root,
        libc::SYS_ptrace,
        libc::SYS_setns,
        libc::SYS_unshare,
        libc::SYS_kexec_load,
        libc::SYS_bpf,
        libc::SYS_perf_event_open,
        libc::SYS_open_by_handle_at,
        libc::SYS_keyctl,
        libc::SYS_add_key,
        libc::SYS_request_key,
    ];

    let mut filter = vec![
        stmt(BPF_LD | BPF_W | BPF_ABS, 4), // seccomp_data.arch
        jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD | BPF_W | BPF_ABS, 0), // seccomp_data.nr
        stmt(BPF_ALU | BPF_AND | BPF_K, X32_SYSCALL_BIT),
        jump(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0),
        stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        stmt(BPF_LD | BPF_W | BPF_ABS, 0), // reload syscall number
    ];

    for nr in dangerous {
        filter.push(jump(BPF_JMP | BPF_JEQ | BPF_K, *nr as u32, 0, 1));
        filter.push(stmt(BPF_RET | BPF_K, EPERM_RET));
    }
    filter.push(jump(
        BPF_JMP | BPF_JEQ | BPF_K,
        libc::SYS_socket as u32,
        0,
        5,
    ));
    filter.push(stmt(BPF_LD | BPF_W | BPF_ABS, 16)); // args[0], low word
    filter.push(jump(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_INET as u32, 0, 1));
    filter.push(stmt(BPF_RET | BPF_K, SECCOMP_RET_TRAP));
    filter.push(jump(BPF_JMP | BPF_JEQ | BPF_K, libc::AF_INET6 as u32, 0, 1));
    filter.push(stmt(BPF_RET | BPF_K, SECCOMP_RET_TRAP));
    filter.push(stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));

    let mut program = libc::sock_fprog {
        len: filter.len() as u16,
        filter: filter.as_mut_ptr(),
    };
    let rc = unsafe {
        libc::syscall(
            libc::SYS_seccomp,
            1usize,
            0usize,
            &mut program as *mut libc::sock_fprog,
        )
    };
    if rc != 0 {
        return Err(format!(
            "seccomp install failed: {}",
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn spawn_keeper(
    rootfs: &Path,
    root: &Path,
    lower: &Path,
    upper: &Path,
    work: &Path,
    socket: &Path,
    cgroup: &Path,
) -> Result<u32, String> {
    let executable = env::current_exe().map_err(io_error)?;
    let ready_path = root
        .parent()
        .ok_or("domain parent missing")?
        .join("keeper.ready");
    let mut command = Command::new("/usr/bin/unshare");
    // Map the trusted broker account as well as root so setup can traverse its
    // private directories. The worker still sees only the mounted/chroot rootfs.
    for (variable, option) in [("SUDO_UID", "--map-users"), ("SUDO_GID", "--map-groups")] {
        if let Ok(value) = env::var(variable) {
            let id: u32 = value.parse().map_err(|_| "invalid sudo identity")?;
            if id != 0 {
                command.arg(format!("{option}={id}:{id}:1"));
            }
        }
    }

    command
        .args([
            "--user",
            "--map-root-user",
            "--mount",
            "--pid",
            "--fork",
            "--net",
            "--ipc",
            "--uts",
            "--",
        ])
        .arg(&executable)
        .arg("worker-init")
        .arg("--rootfs")
        .arg(rootfs)
        .arg("--root")
        .arg(root)
        .arg("--workspace-lower")
        .arg(lower)
        .arg("--upper")
        .arg(upper)
        .arg("--work")
        .arg(work)
        .arg("--effect-socket")
        .arg(socket)
        .arg("--ready")
        .arg(&ready_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    let cgroup_file = attach_before_exec(&mut command, cgroup)?;
    let mut child = command
        .spawn()
        .map_err(|e| format!("unshare failed to spawn: {e}"))?;
    drop(cgroup_file);

    for _ in 0..100 {
        if let Some(status) = child.try_wait().map_err(io_error)? {
            let mut stderr = String::new();
            if let Some(mut pipe) = child.stderr.take() {
                let _ = pipe.read_to_string(&mut stderr);
            }
            return Err(format!(
                "namespace keeper exited early ({status}): {stderr}"
            ));
        }
        let pids = cgroup_pids(cgroup)?;
        if let Some(pid) = pids.into_iter().find(|pid| {
            *pid != child.id()
                && proc_cmdline_contains(*pid, "worker-init")
                && fs::metadata(&ready_path)
                    .map(|m| m.len() == 1)
                    .unwrap_or(false)
        }) {
            return Ok(pid);
        }
        thread::sleep(Duration::from_millis(20));
    }
    let _ = fs::write(cgroup.join("cgroup.kill"), "1");
    let _ = child.wait();
    Err("namespace keeper did not become ready".into())
}

fn configure_cgroup(path: &Path, limits: &Value) -> Result<(), String> {
    let root = Path::new("/sys/fs/cgroup");
    if !root.join("cgroup.controllers").exists() {
        return Err("cgroup v2 not mounted".into());
    }

    let epoch_dir = path.parent().ok_or("invalid cgroup path")?;
    let episode_dir = epoch_dir.parent().ok_or("invalid cgroup path")?;
    let autonomic = episode_dir.parent().ok_or("invalid cgroup path")?;
    if autonomic != root.join("autonomic") {
        return Err("cgroup path escaped autonomic subtree".into());
    }

    fs::create_dir_all(autonomic).map_err(io_error)?;
    enable_controllers(root)?;
    enable_controllers(autonomic)?;
    fs::create_dir_all(episode_dir).map_err(io_error)?;
    enable_controllers(episode_dir)?;
    fs::create_dir_all(epoch_dir).map_err(io_error)?;
    enable_controllers(epoch_dir)?;
    fs::create_dir_all(path).map_err(io_error)?;

    let memory_mb = limits
        .get("memory_mb")
        .and_then(Value::as_u64)
        .unwrap_or(4096)
        .clamp(64, 1_048_576);
    let pids = limits
        .get("pids")
        .and_then(Value::as_u64)
        .unwrap_or(256)
        .clamp(16, 65_536);
    let cpu_quota = limits
        .get("cpu_quota")
        .and_then(Value::as_u64)
        .unwrap_or(2)
        .clamp(1, 1024);
    fs::write(
        path.join("memory.max"),
        format!("{}\n", memory_mb * 1024 * 1024),
    )
    .map_err(io_error)?;
    if path.join("memory.swap.max").exists() {
        fs::write(path.join("memory.swap.max"), "0\n").map_err(io_error)?;
    }
    fs::write(path.join("pids.max"), format!("{pids}\n")).map_err(io_error)?;
    fs::write(
        path.join("cpu.max"),
        format!("{} 100000\n", cpu_quota * 100_000),
    )
    .map_err(io_error)?;
    Ok(())
}

fn enable_controllers(path: &Path) -> Result<(), String> {
    let control = path.join("cgroup.subtree_control");
    if control.exists() {
        fs::write(control, "+cpu +memory +pids\n").map_err(|e| {
            format!(
                "enable cgroup controllers at {} failed: {e}",
                path.display()
            )
        })?;
    }
    Ok(())
}

// Enter the cgroup before unshare/exec can fork any descendants.
fn attach_before_exec(command: &mut Command, cgroup: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .write(true)
        .open(cgroup.join("cgroup.procs"))
        .map_err(io_error)?;
    let fd = file.as_raw_fd();
    unsafe {
        command.pre_exec(move || {
            if libc::write(fd, b"0".as_ptr().cast(), 1) != 1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    Ok(file)
}

fn cgroup_path(episode: &str, epoch: u64, generation: u64) -> Result<PathBuf, String> {
    validate_hex_id(episode, 32, "episode")?;
    Ok(Path::new("/sys/fs/cgroup/autonomic")
        .join(episode)
        .join(format!("epoch-{epoch}"))
        .join(format!("gen-{generation}")))
}

fn set_frozen(cgroup: &Path, frozen: bool) -> Result<(), String> {
    fs::write(
        cgroup.join("cgroup.freeze"),
        if frozen { "1\n" } else { "0\n" },
    )
    .map_err(io_error)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let events = fs::read_to_string(cgroup.join("cgroup.events")).map_err(io_error)?;
        let expected = if frozen { "frozen 1" } else { "frozen 0" };
        if events.lines().any(|line| line.trim() == expected) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("cgroup freeze transition timed out".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn cgroup_pids(cgroup: &Path) -> Result<Vec<u32>, String> {
    let contents = match fs::read_to_string(cgroup.join("cgroup.procs")) {
        Ok(v) => v,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(io_error(e)),
    };
    contents
        .lines()
        .filter(|s| !s.is_empty())
        .map(|s| s.parse::<u32>().map_err(|_| "invalid cgroup pid".into()))
        .collect()
}

fn wait_empty(cgroup: &Path, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        if cgroup_pids(cgroup)?.is_empty() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("timed out waiting for cgroup to become empty".into());
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn next_generation(state_root: &Path, episode: &str, epoch: u64) -> Result<u64, String> {
    let parent = state_root
        .join("domains")
        .join(episode)
        .join(format!("epoch-{epoch}"));
    if !parent.exists() {
        return Ok(0);
    }
    let mut max_seen: Option<u64> = None;
    for entry in fs::read_dir(parent).map_err(io_error)? {
        let name = entry
            .map_err(io_error)?
            .file_name()
            .to_string_lossy()
            .into_owned();
        if let Some(rest) = name.strip_prefix("gen-") {
            if let Ok(value) = rest.parse::<u64>() {
                max_seen = Some(max_seen.map_or(value, |old| old.max(value)));
            }
        }
    }
    Ok(max_seen.map_or(0, |v| v + 1))
}

fn persist_domain(domain: &Domain) -> Result<(), String> {
    write_private_json(&domain.domain_dir.join("domain.json"), domain)
}

fn digest_tree(root: &Path) -> Result<String, String> {
    let mut paths = Vec::new();
    collect_paths(root, root, &mut paths)?;
    paths.sort();
    let mut hasher = Sha256::new();
    for relative in paths {
        let full = root.join(&relative);
        let meta = fs::symlink_metadata(&full).map_err(io_error)?;
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(meta.mode().to_be_bytes());
        hasher.update(meta.len().to_be_bytes());
        if meta.file_type().is_symlink() {
            hasher.update(
                fs::read_link(&full)
                    .map_err(io_error)?
                    .to_string_lossy()
                    .as_bytes(),
            );
        } else if meta.is_file() {
            let mut file = File::open(&full).map_err(io_error)?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = file.read(&mut buf).map_err(io_error)?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
            }
        }
    }
    Ok(hex::encode(hasher.finalize()))
}

fn collect_paths(base: &Path, current: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    for entry in fs::read_dir(current).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        let path = entry.path();
        let relative = path
            .strip_prefix(base)
            .map_err(|_| "path traversal while hashing")?
            .to_path_buf();
        out.push(relative);
        if entry.file_type().map_err(io_error)?.is_dir() {
            collect_paths(base, &path, out)?;
        }
    }
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path) -> Result<(), String> {
    fs::create_dir_all(destination).map_err(io_error)?;
    let status = Command::new("/bin/cp")
        .arg("-a")
        .arg("--reflink=auto")
        .arg(format!("{}/.", source.display()))
        .arg(destination)
        .status()
        .map_err(io_error)?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("checkpoint copy failed: {status}"))
    }
}

fn chroot_to(root: &Path) -> Result<(), String> {
    let c = CString::new(root.as_os_str().as_bytes()).map_err(|_| "root contains NUL")?;
    if unsafe { libc::chroot(c.as_ptr()) } != 0 {
        return Err(format!("chroot failed: {}", io::Error::last_os_error()));
    }
    let slash = CString::new("/").unwrap();
    if unsafe { libc::chdir(slash.as_ptr()) } != 0 {
        return Err(format!("chdir failed: {}", io::Error::last_os_error()));
    }
    Ok(())
}

fn parse_pairs(args: &[String]) -> Result<HashMap<String, String>, String> {
    if !args.len().is_multiple_of(2) {
        return Err("helper arguments must be key/value pairs".into());
    }
    let mut map = HashMap::new();
    for pair in args.chunks(2) {
        if !pair[0].starts_with("--") || map.insert(pair[0].clone(), pair[1].clone()).is_some() {
            return Err("invalid or duplicate helper option".into());
        }
    }
    Ok(map)
}

fn required_opt<'a>(opts: &'a HashMap<String, String>, key: &str) -> Result<&'a str, String> {
    opts.get(key)
        .map(String::as_str)
        .ok_or_else(|| format!("missing {key}"))
}

fn run(program: &str, args: &[&str]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(io_error)?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!(
            "{} {} failed ({}): {}",
            program,
            args.join(" "),
            output.status,
            stderr.trim()
        ))
    }
}
fn run_owned(program: &str, args: Vec<String>) -> Result<(), String> {
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    run(program, &refs)
}

fn path_str(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| "non-UTF8 path rejected".into())
}
fn canonical_dir(path: &Path) -> Result<PathBuf, String> {
    let p = fs::canonicalize(path).map_err(io_error)?;
    if p.is_dir() {
        Ok(p)
    } else {
        Err(format!("not a directory: {}", p.display()))
    }
}
fn canonical_socket(path: &Path) -> Result<PathBuf, String> {
    let p = fs::canonicalize(path).map_err(io_error)?;
    let meta = fs::metadata(&p).map_err(io_error)?;
    if meta.file_type().is_socket() {
        Ok(p)
    } else {
        Err(format!("not a unix socket: {}", p.display()))
    }
}
fn secure_absolute(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        Err("path must be absolute without '..'".into())
    } else {
        Ok(path.to_path_buf())
    }
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && !v.as_bytes().contains(&0))
        .ok_or_else(|| format!("missing/invalid {key}"))
}
fn integer(object: &Map<String, Value>, key: &str) -> Result<u64, String> {
    object
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("missing/invalid {key}"))
}
fn validate_hex_id(value: &str, len: usize, label: &str) -> Result<(), String> {
    if value.len() == len && value.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(format!("invalid {label}"))
    }
}
fn validate_env(key: &str, value: &str) -> Result<(), String> {
    if key.is_empty()
        || key.contains('=')
        || key.as_bytes().contains(&0)
        || value.as_bytes().contains(&0)
        || key.len() + value.len() > 32_768
    {
        Err("invalid environment entry".into())
    } else {
        Ok(())
    }
}
fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
fn io_error(error: io::Error) -> String {
    error.to_string()
}
fn ensure_directory_mode(path: &Path, mode: u32) -> Result<(), String> {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(io_error)
}
fn digest_strings(parts: &[&str]) -> String {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
        h.update([0]);
    }
    hex::encode(h.finalize())
}
fn proc_cmdline_contains(pid: u32, needle: &str) -> bool {
    fs::read(format!("/proc/{pid}/cmdline"))
        .map(|b| String::from_utf8_lossy(&b).contains(needle))
        .unwrap_or(false)
}
fn write_private_json<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).mode(0o600);
    let file = options.open(path).map_err(io_error)?;
    serde_json::to_writer(file, value).map_err(|e| e.to_string())
}

fn read_limited<R: Read>(mut reader: R, limit: usize) -> Result<(Vec<u8>, bool), String> {
    let mut output = Vec::with_capacity(limit.min(8192));
    let mut buf = [0u8; 8192];
    let mut truncated = false;
    loop {
        let n = reader.read(&mut buf).map_err(io_error)?;
        if n == 0 {
            break;
        }
        let room = limit.saturating_sub(output.len());
        if room > 0 {
            output.extend_from_slice(&buf[..n.min(room)]);
        }
        if n > room {
            truncated = true;
        }
    }
    Ok((output, truncated))
}

fn read_frame<R: Read>(input: &mut R) -> Result<Option<Vec<u8>>, String> {
    let mut size = [0u8; 4];
    match input.read_exact(&mut size) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(io_error(e)),
    }
    let length = u32::from_be_bytes(size) as usize;
    if length == 0 || length > MAX_REQUEST {
        return Err("request frame out of bounds".into());
    }
    let mut payload = vec![0u8; length];
    input.read_exact(&mut payload).map_err(io_error)?;
    Ok(Some(payload))
}

fn write_frame<W: Write>(output: &mut W, value: &Value) -> Result<(), String> {
    let payload = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    if payload.len() > MAX_RESPONSE {
        return Err("response frame too large".into());
    }
    output
        .write_all(&(payload.len() as u32).to_be_bytes())
        .map_err(io_error)?;
    output.write_all(&payload).map_err(io_error)?;
    output.flush().map_err(io_error)
}

// Strict standard Base64 decoder sufficient for bounded stdin transport.
fn decode_base64(input: &str) -> Result<Vec<u8>, String> {
    fn value(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    if !input.len().is_multiple_of(4) {
        return Err("invalid base64 length".into());
    }
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let a = value(chunk[0]).ok_or("invalid base64")? as u32;
        let b = value(chunk[1]).ok_or("invalid base64")? as u32;
        let c = if chunk[2] == b'=' {
            0
        } else {
            value(chunk[2]).ok_or("invalid base64")? as u32
        };
        let d = if chunk[3] == b'=' {
            0
        } else {
            value(chunk[3]).ok_or("invalid base64")? as u32
        };
        let padded = chunk[2] == b'=' || chunk[3] == b'=';
        if padded && index + 1 != bytes.len() / 4
            || chunk[2] == b'=' && (chunk[3] != b'=' || b & 15 != 0)
            || chunk[3] == b'=' && chunk[2] != b'=' && c & 3 != 0
        {
            return Err("invalid base64 padding".into());
        }
        let n = (a << 18) | (b << 12) | (c << 6) | d;
        out.push((n >> 16) as u8);
        if chunk[2] != b'=' {
            out.push((n >> 8) as u8);
        }
        if chunk[3] != b'=' {
            out.push(n as u8);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_parent_traversal() {
        assert!(secure_absolute(Path::new("/var/lib/autonomic/../escape")).is_err());
        assert!(secure_absolute(Path::new("relative/path")).is_err());
    }

    #[test]
    fn validates_hex_episode_ids() {
        assert!(validate_hex_id("0123456789abcdef0123456789abcdef", 32, "episode").is_ok());
        assert!(validate_hex_id("not-hex", 32, "episode").is_err());
    }

    #[test]
    fn base64_decoder_is_bounded_and_strict() {
        assert_eq!(decode_base64("aGVsbG8=").unwrap(), b"hello");
        assert!(decode_base64("not base64").is_err());
        for malformed in ["aA=a", "aA==aA==", "aB==", "aGV="] {
            assert!(decode_base64(malformed).is_err(), "accepted {malformed}");
        }
    }

    #[test]
    fn framed_protocol_rejects_zero_and_oversize() {
        let zero_size = 0u32.to_be_bytes();
        let mut zero = &zero_size[..];
        assert!(read_frame(&mut zero).is_err());
        let size = (MAX_REQUEST as u32 + 1).to_be_bytes();
        let mut big = &size[..];
        assert!(read_frame(&mut big).is_err());
    }
}
