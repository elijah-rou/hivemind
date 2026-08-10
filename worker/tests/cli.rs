use std::process::Command;
use std::time::{Duration, Instant};

#[test]
fn hostname_replica_address_fails_before_reconnect_loop() {
    let start = Instant::now();
    let output = Command::new(env!("CARGO_BIN_EXE_hivemind-worker"))
        .args(["run", "localhost:9000", "--runtime", "simulated"])
        .output()
        .expect("worker CLI must execute");

    assert!(!output.status.success());
    assert!(start.elapsed() < Duration::from_secs(2));
    let stderr = String::from_utf8(output.stderr).expect("stderr must be UTF-8");
    assert!(stderr.contains("replica address must be an IP socket address: localhost:9000"));
    assert!(!stderr.contains("reconnecting in"));
}
