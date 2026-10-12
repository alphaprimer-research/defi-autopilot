"""
Yield monitor — queries Aave V3, Compound V3, Fluid lending rates on Arbitrum.
Returns the protocol ID (1/2/3) with the highest supply APY.
"""

import urllib.request
import json
import logging

log = logging.getLogger("yield_monitor")

DEFILLAMA_YIELDS = "https://yields.llama.fi/pools"

POOL_MAP = {
    "aave-v3": 1,
    "compound-v3": 2,
    "fluid-lending": 3,
}

CHAIN = "Arbitrum"
SYMBOL_FILTER = "USDC"
MIN_TVL = 500_000


def fetch_yields():
    req = urllib.request.Request(
        DEFILLAMA_YIELDS,
        headers={"User-Agent": "AlphaPrimer/1.0"},
    )
    resp = urllib.request.urlopen(req, timeout=20)
    pools = json.loads(resp.read().decode())["data"]

    results = []
    for p in pools:
        if p.get("chain") != CHAIN:
            continue
        if SYMBOL_FILTER not in p.get("symbol", ""):
            continue
        project = p.get("project", "")
        if project not in POOL_MAP:
            continue
        tvl = p.get("tvlUsd", 0) or 0
        if tvl < MIN_TVL:
            continue
        apy = p.get("apy", 0) or 0
        if apy <= 0:
            continue

        results.append({
            "project": project,
            "protocol_id": POOL_MAP[project],
            "apy": apy,
            "tvl": tvl,
            "symbol": p.get("symbol", ""),
            "pool": p.get("pool", ""),
        })

    results.sort(key=lambda x: x["apy"], reverse=True)
    return results


def get_best_protocol():
    yields = fetch_yields()
    if not yields:
        log.warning("No yield data available")
        return None
    best = yields[0]
    log.info(
        f"Best yield: {best['project']} ({best['protocol_id']}) "
        f"APY={best['apy']:.2f}% TVL=${best['tvl']/1e6:.1f}M"
    )
    for y in yields:
        log.debug(
            f"  {y['project']}: {y['apy']:.2f}% "
            f"TVL=${y['tvl']/1e6:.1f}M (id={y['protocol_id']})"
        )
    return best


def should_rebalance(current_protocol_id, min_diff_pct=2.0):
    yields = fetch_yields()
    if not yields:
        return False, None, None

    best = yields[0]
    current = next((y for y in yields if y["protocol_id"] == current_protocol_id), None)
    current_apy = current["apy"] if current else 0

    diff = best["apy"] - current_apy
    if best["protocol_id"] == current_protocol_id:
        return False, best, current_apy

    if diff >= min_diff_pct:
        log.info(
            f"Rebalance signal: {best['project']} {best['apy']:.2f}% "
            f"vs current {current_apy:.2f}% (diff {diff:.2f}%)"
        )
        return True, best, current_apy

    log.debug(f"No rebalance: diff {diff:.2f}% < threshold {min_diff_pct}%")
    return False, best, current_apy
