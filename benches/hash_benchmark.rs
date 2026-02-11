use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use std::path::Path;

use coreutils_rs::hash::{self, HashAlgorithm};

/// Create test data of the given size for benchmarking.
fn make_test_data(size: usize) -> Vec<u8> {
    (0..size).map(|i| (i % 251) as u8).collect()
}

fn bench_hash_bytes(c: &mut Criterion) {
    let sizes = [1024, 64 * 1024, 1024 * 1024, 10 * 1024 * 1024];

    let mut group = c.benchmark_group("hash_bytes");
    for &size in &sizes {
        let data = make_test_data(size);
        let label = if size >= 1024 * 1024 {
            format!("{}MB", size / (1024 * 1024))
        } else {
            format!("{}KB", size / 1024)
        };

        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("sha256", &label), &data, |b, data| {
            b.iter(|| hash::hash_bytes(HashAlgorithm::Sha256, data));
        });

        group.bench_with_input(BenchmarkId::new("md5", &label), &data, |b, data| {
            b.iter(|| hash::hash_bytes(HashAlgorithm::Md5, data));
        });

        group.bench_with_input(BenchmarkId::new("blake2b", &label), &data, |b, data| {
            b.iter(|| hash::hash_bytes(HashAlgorithm::Blake2b, data));
        });
    }
    group.finish();
}

fn bench_hash_file(c: &mut Criterion) {
    // Use pre-existing benchmark files if available
    let test_files: Vec<(&str, &str)> = vec![
        ("10MB", "/tmp/bench-data/file_1.bin"),
        ("100MB", "/tmp/bench-data/large_1.bin"),
    ];

    let mut group = c.benchmark_group("hash_file");
    group.sample_size(10); // Fewer samples for large files

    for (label, path) in &test_files {
        let file_path = Path::new(path);
        if !file_path.exists() {
            continue;
        }
        let size = std::fs::metadata(file_path).unwrap().len();
        group.throughput(Throughput::Bytes(size));

        group.bench_with_input(
            BenchmarkId::new("sha256", label),
            file_path,
            |b, path| {
                b.iter(|| hash::hash_file(HashAlgorithm::Sha256, path).unwrap());
            },
        );

        group.bench_with_input(BenchmarkId::new("md5", label), file_path, |b, path| {
            b.iter(|| hash::hash_file(HashAlgorithm::Md5, path).unwrap());
        });

        group.bench_with_input(
            BenchmarkId::new("blake2b", label),
            file_path,
            |b, path| {
                b.iter(|| hash::hash_file(HashAlgorithm::Blake2b, path).unwrap());
            },
        );
    }
    group.finish();
}

fn bench_parallel_hash(c: &mut Criterion) {
    use rayon::prelude::*;

    // Use 4 x 100MB files for parallel benchmark
    let files: Vec<String> = (1..=4)
        .map(|i| format!("/tmp/bench-data/large_{}.bin", i))
        .collect();

    // Skip if files don't exist
    if !files.iter().all(|f| Path::new(f).exists()) {
        return;
    }

    let total_size: u64 = files
        .iter()
        .map(|f| std::fs::metadata(f).unwrap().len())
        .sum();

    let mut group = c.benchmark_group("parallel_hash");
    group.sample_size(10);
    group.throughput(Throughput::Bytes(total_size));

    group.bench_function("sha256_4x100MB", |b| {
        b.iter(|| {
            let _results: Vec<_> = files
                .par_iter()
                .map(|f| hash::hash_file(HashAlgorithm::Sha256, Path::new(f)).unwrap())
                .collect();
        });
    });

    group.bench_function("md5_4x100MB", |b| {
        b.iter(|| {
            let _results: Vec<_> = files
                .par_iter()
                .map(|f| hash::hash_file(HashAlgorithm::Md5, Path::new(f)).unwrap())
                .collect();
        });
    });

    group.bench_function("blake2b_4x100MB", |b| {
        b.iter(|| {
            let _results: Vec<_> = files
                .par_iter()
                .map(|f| hash::hash_file(HashAlgorithm::Blake2b, Path::new(f)).unwrap())
                .collect();
        });
    });

    group.finish();
}

criterion_group!(benches, bench_hash_bytes, bench_hash_file, bench_parallel_hash);
criterion_main!(benches);
