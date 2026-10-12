"""
Vault operator — interacts with AlphaPrimerVault on Arbitrum.
Calls rebalanceTo(), harvest(), and reads vault state.
"""

import json
import logging
from pathlib import Path
from web3 import Web3
from eth_account import Account

log = logging.getLogger("vault_operator")

VAULT_ABI = [
    {"inputs": [], "name": "activeProtocol", "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "totalAssets", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "totalSupply", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "highWaterMark", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "accruedFees", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastHarvest", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "perfFeeBps", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "mgmtFeeBps", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "depositsPaused", "outputs": [{"type": "bool"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "version", "outputs": [{"type": "string"}], "stateMutability": "pure", "type": "function"},
    {"inputs": [{"type": "uint8", "name": "toProtocol"}], "name": "rebalanceTo", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "harvest", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "deployIdle", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
]

PROTOCOL_NAMES = {0: "idle", 1: "Aave", 2: "Compound", 3: "Fluid"}


class VaultOperator:
    def __init__(self, rpc_url, vault_address, strategist_pk):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.vault = self.w3.eth.contract(
            address=Web3.to_checksum_address(vault_address),
            abi=VAULT_ABI,
        )
        self.account = Account.from_key(strategist_pk)
        self.address = self.account.address

    def _send_tx(self, fn, gas=300_000):
        base_fee = self.w3.eth.get_block("latest")["baseFeePerGas"]
        tx = fn.build_transaction({
            "from": self.address,
            "gas": gas,
            "maxFeePerGas": int(base_fee * 2),
            "maxPriorityFeePerGas": int(base_fee * 0.1),
            "nonce": self.w3.eth.get_transaction_count(self.address),
            "chainId": 42161,
            "type": 2,
        })
        signed = self.w3.eth.account.sign_transaction(tx, self.account.key)
        tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        return tx_hash.hex(), receipt["status"]

    def get_state(self):
        return {
            "version": self.vault.functions.version().call(),
            "active_protocol": self.vault.functions.activeProtocol().call(),
            "active_name": PROTOCOL_NAMES.get(self.vault.functions.activeProtocol().call(), "?"),
            "total_assets": self.vault.functions.totalAssets().call(),
            "total_supply": self.vault.functions.totalSupply().call(),
            "high_water_mark": self.vault.functions.highWaterMark().call(),
            "accrued_fees": self.vault.functions.accruedFees().call(),
            "last_harvest": self.vault.functions.lastHarvest().call(),
            "deposits_paused": self.vault.functions.depositsPaused().call(),
            "perf_fee_bps": self.vault.functions.perfFeeBps().call(),
            "mgmt_fee_bps": self.vault.functions.mgmtFeeBps().call(),
        }

    def rebalance_to(self, protocol_id):
        log.info(f"Rebalancing to protocol {protocol_id} ({PROTOCOL_NAMES.get(protocol_id, '?')})")
        tx_hash, status = self._send_tx(
            self.vault.functions.rebalanceTo(protocol_id), gas=500_000
        )
        log.info(f"Rebalance TX: {tx_hash} status={status}")
        return tx_hash, status

    def harvest(self):
        log.info("Harvesting yields")
        tx_hash, status = self._send_tx(self.vault.functions.harvest())
        log.info(f"Harvest TX: {tx_hash} status={status}")
        return tx_hash, status

    def deploy_idle(self):
        log.info("Deploying idle funds")
        tx_hash, status = self._send_tx(self.vault.functions.deployIdle())
        log.info(f"DeployIdle TX: {tx_hash} status={status}")
        return tx_hash, status

    def log_state(self):
        s = self.get_state()
        log.info(
            f"Vault v{s['version']}: "
            f"assets=${s['total_assets']/1e6:.2f} "
            f"supply={s['total_supply']/1e12:.6f} "
            f"fees=${s['accrued_fees']/1e6:.4f} "
            f"active={s['active_name']} "
            f"paused={s['deposits_paused']}"
        )
        return s
