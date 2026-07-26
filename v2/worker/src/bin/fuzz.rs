use hivemind_worker::prng::{Prng, Ratio};
use hivemind_worker::sim::runner::{self, Outcome, SimConfig, LIVENESS_RETRY_GRACE_TICKS};

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

const PARAM_COUNT: u64 = 12;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    let mut mode = "sequential".to_string();
    let mut seed_count: u64 = 1000;
    let mut budget_secs: u64 = 0;
    let mut thread_count: usize = 0;
    let mut mutate = false;
    let mut replay_seed: Option<u64> = None;
    let mut verbose = false;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "sequential" => {
                mode = "sequential".into();
                i += 1;
            }
            "random" => {
                mode = "random".into();
                i += 1;
            }
            "replay" if i + 1 < args.len() => {
                mode = "replay".into();
                replay_seed = args[i + 1].parse().ok();
                i += 2;
            }
            "--seeds" if i + 1 < args.len() => {
                seed_count = args[i + 1].parse().unwrap_or(1000);
                i += 2;
            }
            "--budget" if i + 1 < args.len() => {
                budget_secs = args[i + 1].parse().unwrap_or(0);
                i += 2;
            }
            "--threads" if i + 1 < args.len() => {
                thread_count = args[i + 1].parse().unwrap_or(1);
                i += 2;
            }
            "--mutate" => {
                mutate = true;
                i += 1;
            }
            "--verbose" => {
                verbose = true;
                i += 1;
            }
            _ => {
                i += 1;
            }
        }
    }

    if mode == "replay" {
        let seed = replay_seed.unwrap_or_else(|| {
            eprintln!("usage: fuzz replay <SEED> [--verbose] [--mutate]");
            std::process::exit(2);
        });
        run_replay(seed, mutate, verbose);
        return;
    }

    run_fuzzer(&mode, seed_count, budget_secs, thread_count, mutate);
}

#[derive(Clone, Copy)]
enum FuzzMode {
    Sequential,
    Random,
}

#[derive(Default)]
struct ThreadResult {
    seeds_tested: u64,
    failures_found: u64,
    last_failure_seed: u64,
}

fn run_fuzzer(
    mode: &str,
    seed_count: u64,
    budget_secs: u64,
    thread_count_arg: usize,
    mutate: bool,
) {
    let start = Instant::now();
    let mode = match mode {
        "random" => FuzzMode::Random,
        _ => FuzzMode::Sequential,
    };
    let thread_count = resolve_thread_count(seed_count, thread_count_arg);

    let mut random_seeds = Vec::new();
    if matches!(mode, FuzzMode::Random) {
        random_seeds = Vec::with_capacity(seed_count as usize);
        let mut random_prng = Prng::init(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
        );
        for _ in 0..seed_count {
            random_seeds.push(random_prng.next());
        }
    }
    let random_seeds = Arc::new(random_seeds);

    let corpus = OpenOptions::new()
        .create(true)
        .append(true)
        .open("fuzz_failures.jsonl")
        .ok();
    let corpus = Arc::new(Mutex::new(corpus));

    eprintln!(
        "[fuzz] mode={} seeds={seed_count} threads={thread_count} budget={budget_secs}s mutate={mutate}",
        mode_name(mode)
    );

    let mut handles = Vec::with_capacity(thread_count);
    for thread_index in 0..thread_count {
        let (start_index, end_index) = thread_range(seed_count, thread_count, thread_index);
        let random_seeds = Arc::clone(&random_seeds);
        let corpus = Arc::clone(&corpus);
        handles.push(thread::spawn(move || {
            fuzz_worker(
                mode,
                start_index,
                end_index,
                random_seeds,
                start,
                budget_secs,
                mutate,
                corpus,
            )
        }));
    }

    let mut seeds_tested: u64 = 0;
    let mut failures_found: u64 = 0;
    let mut last_failure_seed: u64 = 0;
    for handle in handles {
        let result = handle.join().expect("fuzz worker thread panicked");
        seeds_tested += result.seeds_tested;
        failures_found += result.failures_found;
        last_failure_seed = last_failure_seed.max(result.last_failure_seed);
    }

    let elapsed = start.elapsed().as_secs_f64();
    let rate = seeds_tested as f64 / elapsed.max(0.001);
    if last_failure_seed > 0 {
        eprintln!(
            "[fuzz] {:.0}:{:02.0} | seeds: {seeds_tested} | failures: {failures_found} | rate: {rate:.1}/s | last_fail: seed={last_failure_seed}",
            (elapsed / 60.0).floor(),
            elapsed % 60.0
        );
    }
    eprintln!(
        "{{\"elapsed_secs\":{elapsed:.1},\"seeds_tested\":{seeds_tested},\"failures_found\":{failures_found},\"seeds_per_sec\":{rate:.1},\"corpus\":\"fuzz_failures.jsonl\"}}"
    );

    if failures_found > 0 {
        std::process::exit(1);
    }
}

fn resolve_thread_count(seed_count: u64, thread_count_arg: usize) -> usize {
    if seed_count == 0 {
        return 1;
    }

    let requested = if thread_count_arg == 0 {
        std::thread::available_parallelism()
            .map(|count| count.get())
            .unwrap_or(1)
    } else {
        thread_count_arg
    };
    assert!(requested > 0, "thread count must be positive or 0 for auto");

    requested.min(seed_count as usize).max(1)
}

fn thread_range(seed_count: u64, thread_count: usize, thread_index: usize) -> (u64, u64) {
    assert!(thread_count > 0, "thread count must be positive");
    assert!(thread_index < thread_count, "thread index out of bounds");

    let base = seed_count / thread_count as u64;
    let extra = seed_count % thread_count as u64;
    let index = thread_index as u64;
    let start = index * base + index.min(extra);
    let len = base + u64::from(index < extra);
    (start, start + len)
}

fn fuzz_worker(
    mode: FuzzMode,
    start_index: u64,
    end_index: u64,
    random_seeds: Arc<Vec<u64>>,
    start: Instant,
    budget_secs: u64,
    mutate: bool,
    corpus: Arc<Mutex<Option<File>>>,
) -> ThreadResult {
    let mut thread_result = ThreadResult::default();

    for index in start_index..end_index {
        if budget_secs > 0 && start.elapsed().as_secs() >= budget_secs {
            break;
        }

        let seed = match mode {
            FuzzMode::Sequential => index,
            FuzzMode::Random => random_seeds[index as usize],
        };

        let mut config = base_config();
        if mutate {
            config = mutate_config(config, seed);
        }
        config.seed = seed;

        let result = runner::run(&config);
        thread_result.seeds_tested += 1;

        if result.outcome != Outcome::Passed {
            thread_result.failures_found += 1;
            thread_result.last_failure_seed = seed;
            let mut corpus = corpus.lock().expect("fuzz failure corpus mutex poisoned");
            record_failure(&mut corpus, seed, &config, &result);
            eprintln!(
                "[fuzz] FAILURE seed={seed} outcome={:?} violations={} p1={} p2={}",
                result.outcome, result.safety_violations, result.phase1_ticks, result.phase2_ticks
            );
        }
    }

    thread_result
}

fn mode_name(mode: FuzzMode) -> &'static str {
    match mode {
        FuzzMode::Sequential => "sequential",
        FuzzMode::Random => "random",
    }
}

fn run_replay(seed: u64, mutate: bool, _verbose: bool) {
    let mut config = base_config();
    if mutate {
        config = mutate_config(config, seed);
    }
    config.seed = seed;

    eprintln!(
        "[fuzz] replay seed={seed} config: agents={} safety={} pods={} partition={}/{} heal={}/{} pull_fail={}/{} crash={}/{} drop={}/{} replay={}/{} path_capacity={}",
        config.agent_count, config.safety_ticks, config.pod_count,
        config.partition_probability.numerator, config.partition_probability.denominator,
        config.heal_probability.numerator, config.heal_probability.denominator,
        config.image_pull_failure_rate.numerator, config.image_pull_failure_rate.denominator,
        config.container_crash_rate.numerator, config.container_crash_rate.denominator,
        config.drop_rate.numerator, config.drop_rate.denominator,
        config.replay_rate.numerator, config.replay_rate.denominator,
        config.path_max_capacity,
    );

    let result = runner::run(&config);

    eprintln!(
        "[fuzz] result: outcome={:?} p1={} p2={} violations={}",
        result.outcome, result.phase1_ticks, result.phase2_ticks, result.safety_violations
    );

    if result.outcome != Outcome::Passed {
        std::process::exit(1);
    }
}

fn base_config() -> SimConfig {
    SimConfig {
        seed: 0,
        ..Default::default()
    }
}

fn random_ratio(prng: &mut Prng, max_num: u32, denom: u32) -> Ratio {
    Ratio::new(prng.bounded(max_num as u64 + 1) as u32, denom)
}

fn mutate_config(base: SimConfig, seed: u64) -> SimConfig {
    let mut prng = Prng::init(seed ^ 0xC00F16);
    let mut config = base;

    let param = prng.bounded(PARAM_COUNT);
    match param {
        0 => config.agent_count = 1 + prng.bounded(8) as usize,
        1 => config.pod_count = 5 + prng.bounded(45) as u32,
        2 => config.partition_probability = random_ratio(&mut prng, 15, 100),
        3 => config.heal_probability = random_ratio(&mut prng, 20, 100),
        4 => config.image_pull_failure_rate = random_ratio(&mut prng, 30, 100),
        5 => config.container_crash_rate = random_ratio(&mut prng, 10, 100),
        6 => config.gpu_failure_rate = random_ratio(&mut prng, 10, 100),
        7 => config.safety_ticks = 100 + prng.bounded(900),
        8 => config.liveness_ticks = 100 + prng.bounded(400),
        9 => config.drop_rate = random_ratio(&mut prng, 5, 100),
        10 => config.replay_rate = random_ratio(&mut prng, 3, 100),
        11 => config.path_max_capacity = 1 + prng.bounded(64) as usize,
        _ => unreachable!("bounded mutation parameter must be exhaustive"),
    }
    config.liveness_ticks = config.liveness_ticks.max(LIVENESS_RETRY_GRACE_TICKS);

    config
}

fn record_failure(
    file: &mut Option<std::fs::File>,
    seed: u64,
    config: &SimConfig,
    result: &runner::SimResult,
) {
    let f = match file.as_mut() {
        Some(f) => f,
        None => return,
    };
    let line = format!(
        "{{\"engine\":\"rust\",\"seed\":{seed},\"outcome\":\"{:?}\",\"config\":{{\"agents\":{},\"pods\":{},\"partition\":\"{}/{}\",\"heal\":\"{}/{}\",\"pull_fail\":\"{}/{}\",\"crash\":\"{}/{}\",\"drop\":\"{}/{}\",\"replay\":\"{}/{}\",\"path_capacity\":{}}},\"result\":{{\"p1\":{},\"p2\":{},\"violations\":{},\"messages\":{}}}}}\n",
        result.outcome, config.agent_count, config.pod_count,
        config.partition_probability.numerator, config.partition_probability.denominator,
        config.heal_probability.numerator, config.heal_probability.denominator,
        config.image_pull_failure_rate.numerator, config.image_pull_failure_rate.denominator,
        config.container_crash_rate.numerator, config.container_crash_rate.denominator,
        config.drop_rate.numerator, config.drop_rate.denominator,
        config.replay_rate.numerator, config.replay_rate.denominator,
        config.path_max_capacity,
        result.phase1_ticks, result.phase2_ticks, result.safety_violations, result.messages_sent
    );
    let _ = f.write_all(line.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutated_config_keeps_liveness_above_retry_grace() {
        let config = mutate_config(
            SimConfig {
                liveness_ticks: 1,
                ..Default::default()
            },
            8,
        );
        assert!(config.liveness_ticks >= LIVENESS_RETRY_GRACE_TICKS);
    }

    #[test]
    fn thread_ranges_cover_each_seed_once() {
        let ranges: Vec<(u64, u64)> = (0..4).map(|i| thread_range(10, 4, i)).collect();
        assert_eq!(ranges, vec![(0, 3), (3, 6), (6, 8), (8, 10)]);

        let mut seeds = Vec::new();
        for (start, end) in ranges {
            seeds.extend(start..end);
        }
        assert_eq!(seeds, (0..10).collect::<Vec<u64>>());
    }

    #[test]
    fn thread_count_is_bounded_by_seed_count() {
        assert_eq!(resolve_thread_count(3, 8), 3);
        assert_eq!(resolve_thread_count(0, 8), 1);
    }
}
