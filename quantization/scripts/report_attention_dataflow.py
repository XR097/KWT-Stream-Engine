"""Analytical traffic/capacity budget; no inferred RTL area or cycle estimates."""
import os
import argparse
import json
from pathlib import Path


def budget():
    n, d = 99, 64
    matrix = n*d
    kv = 2*matrix
    weight_block = (4*d*d+2*d*256)//2
    rows = []
    for tile in (1, 4, 8, 16, 99):
        tiles = (n+tile-1)//tile
        for pbits in (8, 12):
            packed_p = (tile*n*pbits+7)//8
            aligned_p = tile*n*2
            rows.append({
                "query_tile_rows": tile, "probability_bits": pbits, "query_tiles": tiles,
                "kv_offchip_bytes_per_block_without_retention": tiles*kv,
                "kv_offchip_bytes_per_block_with_retention": kv,
                "kv_local_read_bytes_per_block_scalar_row_schedule": n*kv,
                "kv_local_read_bytes_per_block_broadcast_across_query_tile": tiles*kv,
                "local_read_reduction_requires_broadcast_or_register_reuse": True,
                "scratch_buffers_logical_bytes": {
                    "q_tile_a8": tile*d,
                    "qk_int32_accumulators": tile*n*4,
                    "score_tile_a8": tile*n,
                    "exp_tile_u16": tile*n*2,
                    "probability_tight_packing": packed_p,
                    "probability_16bit_words": aligned_p,
                    "pv_int32_accumulators": tile*d*4},
                "conservative_attention_live_bytes_with_all_named_buffers":
                    3*matrix + tile*d + tile*n*4 + tile*n + tile*n*2 + aligned_p + tile*d*4,
            })
    return {
        "scope": "analytical per encoder block; all W4 weights, A8 QKV, checked int32 MAC/partial sums",
        "no_rtl_synthesis_or_bus_measurement": True,
        "shape": {"tokens": n, "channels": d, "blocks": 12},
        "resident_k_bytes": matrix, "resident_v_bytes": matrix,
        "minimum_kv_resident_bytes": kv,
        "kv_16bit_word_storage_bytes": 2*kv,
        "all_w4_weight_bytes_per_block": weight_block,
        "all_w4_weight_bytes_encoder": 12*weight_block,
        "weight_fetch_scope": "load each block once per task if retained across query tiles; no weight reuse across different blocks",
        "rows": rows,
        "materialized_attention_lower_bound": {
            "score_a8_write_plus_read_bytes": 2*n*n,
            "p8_write_plus_read_bytes": 2*n*n,
            "p12_tightly_packed_write_plus_read_bytes": 2*((n*n*12+7)//8),
            "p12_16bit_word_write_plus_read_bytes": 4*n*n,
            "assumption": "one write and one read; extra max/exp passes and DMA alignment may add traffic"},
        "int32_absolute_partial_sum_bounds_without_bias": {
            "qk_a8_times_a8_length64": d*128*128,
            "pv_p7_times_a8_length99": n*(1<<7)*128,
            "pv_p11_times_a8_length99": n*(1<<11)*128,
            "linear_a8_times_w4_length256": 256*128*8,
            "note": "conservative mathematical bounds, not observed peaks; bias separately checked by frozen runtime"},
        "capacity_caveats": [
            "logical byte capacity assumes packing two A8 values in a 16-bit SRAM word",
            "named scratch buffers are a conservative sum; lifetime reuse can reduce it",
            "SRAM macro rounding/banks/ports/ECC and DMA bursts excluded",
            "on-chip retention reduces off-chip traffic but not automatically SRAM accesses",
            "no cross-transformer-block tile fusion assumed; next attention block requires all tokens",
            "CPU timing cannot estimate memory-wall behavior or RTL cycles"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    args = ap.parse_args()
    out = Path(args.data_root)/"experiments"/"w4w8_nonlinear_v1"/"reports"
    out.mkdir(parents=True, exist_ok=True)
    data = budget()
    (out/"attention_dataflow.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
    lines = ["# Attention dataflow capacity and traffic budget", "",
             "Analytical model; no RTL area, bus bandwidth or cycle measurement.", "",
             "99 tokens × 64 channels; Q/K/V A8; all W4; MAC and partial accumulators int32.", "",
             "K+V require 12,672 logical bytes per block. Pack two A8 elements per 16-bit SRAM word to preserve this capacity.", "",
             "| Query tile | K/V off-chip without retention | K/V off-chip with retention | QK int32 scratch | PV int32 scratch |", 
             "|---:|---:|---:|---:|---:|"]
    for row in data["rows"]:
        if row["probability_bits"] != 8:
            continue
        b = row["scratch_buffers_logical_bytes"]
        lines.append("| %d | %d | %d | %d | %d |" % (row["query_tile_rows"], row["kv_offchip_bytes_per_block_without_retention"], row["kv_offchip_bytes_per_block_with_retention"], b["qk_int32_accumulators"], b["pv_int32_accumulators"]))
    lines += ["", "One block has 24,576 packed W4 weight bytes; all 12 blocks total 294,912 bytes. Loading a block once and keeping it across query tiles avoids weight reloads. K/V are activations, not projection weights.", "",
              "A tile of 8 can reuse each K/V read across 8 queries when the MAC array supports broadcast/register reuse. A sequential row engine retains K/V on chip but still reads them 99 times from SRAM.", "",
              "Keep int32 only for partial sums until the declared full dot product finishes. Then apply the existing rounding/saturation once. Never requantize reduction chunks independently.", "",
              "Recommended evaluation architecture: K/V resident, current block weight cache, query tiles 1 and 8, row-local exp/probability buffer. Bank/port bandwidth must be checked in RTL before selecting a tile size.", "",
              "A next Transformer block's attention needs all preceding block token outputs. Row fusion through attention/row-local operators within one block does not permit arbitrary cross-block streaming.", ""]
    (out/"attention_dataflow.md").write_text("\n".join(lines), encoding="utf-8")
    print(out/"attention_dataflow.md")


if __name__ == "__main__":
    main()
