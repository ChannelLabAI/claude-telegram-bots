export type MetricName =
  | "append_latency_ms"
  | "lock_wait_ms"
  | "projection_lag_ms"
  | "checkpoint_duration_ms"
  | "backup_duration_ms"
  | "restore_replay_duration_ms"
  | "free_disk_percent"
  | "free_disk_bytes";

export type MetricSample = Readonly<{
  name: MetricName;
  value: number;
  observed_at: string;
}>;

export type SloBreach = Readonly<{
  metric: MetricName;
  threshold: string;
  observed: number;
}>;

function percentile(values: readonly number[], quantile: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.ceil(quantile * sorted.length) - 1]!;
}

export class EventLayerMetrics {
  readonly #samples: MetricSample[] = [];

  record(name: MetricName, value: number, observedAt = new Date()): void {
    if (!Number.isFinite(value) || value < 0) throw new Error(`invalid ${name} sample`);
    this.#samples.push({ name, value, observed_at: observedAt.toISOString() });
  }

  snapshot(): readonly MetricSample[] {
    return [...this.#samples];
  }

  evaluate(): readonly SloBreach[] {
    const values = (name: MetricName) =>
      this.#samples.filter((sample) => sample.name === name).map((sample) => sample.value);
    const breaches: SloBreach[] = [];
    const append = values("append_latency_ms");
    const lock = values("lock_wait_ms");
    const projection = values("projection_lag_ms");
    const checkpoint = values("checkpoint_duration_ms");
    const backup = values("backup_duration_ms");
    const restore = values("restore_replay_duration_ms");
    const freePercent = values("free_disk_percent").at(-1);
    const freeBytes = values("free_disk_bytes").at(-1);
    const add = (metric: MetricName, threshold: string, observed: number, failed: boolean) => {
      if (failed) breaches.push({ metric, threshold, observed });
    };
    add("append_latency_ms", "p95<100", percentile(append, 0.95), percentile(append, 0.95) >= 100);
    add("append_latency_ms", "p99<250", percentile(append, 0.99), percentile(append, 0.99) >= 250);
    add("lock_wait_ms", "p95<50", percentile(lock, 0.95), percentile(lock, 0.95) >= 50);
    add("lock_wait_ms", "single<2000", Math.max(0, ...lock), Math.max(0, ...lock) >= 2_000);
    add("projection_lag_ms", "p95<5000", percentile(projection, 0.95), percentile(projection, 0.95) >= 5_000);
    add("checkpoint_duration_ms", "single<60000", Math.max(0, ...checkpoint), Math.max(0, ...checkpoint) >= 60_000);
    add("backup_duration_ms", "single<900000", Math.max(0, ...backup), Math.max(0, ...backup) >= 900_000);
    add("restore_replay_duration_ms", "single<3600000", Math.max(0, ...restore), Math.max(0, ...restore) >= 3_600_000);
    if (freePercent !== undefined) {
      add("free_disk_percent", "warning>=30", freePercent, freePercent < 30);
      add("free_disk_percent", "stop-writes>=15", freePercent, freePercent < 15);
    }
    if (freeBytes !== undefined) {
      add("free_disk_bytes", "stop-writes>=10737418240", freeBytes, freeBytes < 10 * 1024 ** 3);
    }
    return breaches;
  }
}
