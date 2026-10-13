"""
Vault operator — interacts with AlphaPrimerVault on Arbitrum.
Calls rebalanceTo(), harvest(), and reads vault state.
Supports RPC fallback across multiple endpoints.
"""

import logging
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
    {"inputs": [{"type": "uint8", "name": "toProtocol"}, {"type": "uint256", "name": "minReceived"}], "name": "rebalanceTo", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "harvest", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"inputs": [], "name": "deployIdle", "outputs": [], "stateMutability": "nonpayable", "type": "function"},
]

PROTOCOL_NAMES = {0: "idle", 1: "Aave", 2: "Compound", 3: "Fluid"}

FALLBACK_RPCS = [
    "https://arbitrum.drpc.org",
    "https://arb-mainnet.g.alchemy.com/v2/demo",
    "https://arbitrum-one-rpc.publicnode.com",
]


class VaultOperator:
    def __init__(self, rpc_url, vault_address, strategist_pk):
        self.rpc_urls = [rpc_url] + FALLBACK_RPCS
        self.vault_address = Web3.to_checksum_address(vault_address)
        self.account = Account.from_key(strategist_pk)
        self.address = self.account.address
        self._connect(0)

    def _connect(self, index):
        url = self.rpc_urls[index % len(self.rpc_urls)]
        self.w3 = Web3(Web3.HTTPProvider(url, request_kwargs={"timeout": 15}))
        self.vault = self.w3.eth.contract(
            address=self.vault_address, abi=VAULT_ABI
        )
        self._rpc_index = index
        log.info(f"RPC connected: {url[:50]}")

    def _call_with_fallback(self, fn):
        last_err = None
        for i in range(len(self.rpc_urls)):
            idx = (self._rpc_index + i) % len(self.rpc_urls)
            if i > 0:
                self._connect(idx)
            try:
                return fn()
            except Exception as e:
                last_err = e
                log.warning(f"RPC {idx} failed: {e}")
        raise last_err

    def _send_tx(self, fn, gas=300_000):
        def _do():
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
            raw = getattr(signed, 'raw_transaction', None) or signed.rawTransaction
            tx_hash = self.w3.eth.send_raw_transaction(raw)
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
            return tx_hash.hex(), receipt["status"]
        return self._call_with_fallback(_do)

    def get_state(self):
        def _do():
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
        return self._call_with_fallback(_do)

    def rebalance_to(self, protocol_id):
        log.info(f"Rebalancing to protocol {protocol_id} ({PROTOCOL_NAMES.get(protocol_id, '?')})")
        current_assets = self.vault.functions.totalAssets().call()
        min_received = current_assets * 995 // 1000
        tx_hash, status = self._send_tx(
            self.vault.functions.rebalanceTo(protocol_id, min_received), gas=500_000
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
