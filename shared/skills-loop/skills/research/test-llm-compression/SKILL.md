---
name: test-llm-compression
description: Run comprehensive LLM-based compression tests on text samples with multi-stage validation, baseline comparison, reversibility drift detection, and pattern tracking.
category: research
trigger: "when asked to test or validate text compression, benchmark compression quality, or measure compression with reversibility checks"
version: 1
usage_count: 0
created_at: 2026-04-07T18:52:36.406590
bot: anna
---

## Steps

1. **Prepare test data**: Load sample dataset (specify format/source and sample count)
2. **Design compression prompt**: Create multi-stage prompt (tokenization → replacement rules → output) optimized for target language/domain
3. **Implement quality detector**: Add context-aware validation rules to exclude false positives (e.g., list numbering, locale-specific formatting like 千分位)
4. **Build compression engine**: Implement main compression flow with self-check loop (if compression ratio > threshold, retry with aggressive prompt)
5. **Calculate baseline**: Generate gzip compression ratio as reference baseline for comparison
6. **Test reversibility**: Select subset of samples, compress → decompress → compress → decompress, measure drift between cycles
7. **Track patterns**: Implement hit-rate tracking across all outputs (dictionary matches, reusable patterns, frequency analysis)
8. **Run batch execution**: Execute compression pipeline via CLI subprocess, processing samples in parallel where possible
9. **Aggregate metrics**: Compute overall statistics (compression ratio, quality pass rate, gzip compliance, drift average, pattern coverage)
10. **Output and review**: Write results to structured output file with all metrics, submit to stakeholder for code review and quality validation