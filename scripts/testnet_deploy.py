from brownie import *
from pathlib import Path
import time

GAS_LIMIT = 6721975
def main():
    deps = project.load(  Path.home() / ".brownie" / "packages" / config["dependencies"][0])
    TransparentUpgradeableProxy = deps.TransparentUpgradeableProxy

    owner = accounts.load('iotex-owner')
    deployer = accounts.load('iotex-deployer')

    print(f'contract owner account: {owner.address}\n')

    stIOTX_contract = stIOTX.deploy(
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    stIOTX_proxy = TransparentUpgradeableProxy.deploy(
            stIOTX_contract, deployer, b'',
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    iotexStaking_contract = IOTEXStaking.deploy(
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    iotexStaking_proxy = TransparentUpgradeableProxy.deploy(
            iotexStaking_contract, deployer, b'',
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    redeem_contract = IotexRedeem.deploy(
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    redeem_proxy = TransparentUpgradeableProxy.deploy(
            redeem_contract, deployer, b'',
            {'from': deployer, 'gas': GAS_LIMIT}
            )

    transparent_stIOTX= Contract.from_abi("stIOTX", stIOTX_proxy.address, stIOTX.abi)
    transparent_staking = Contract.from_abi("IOTEXStaking", iotexStaking_proxy.address, IOTEXStaking.abi)
    transparent_redeem  = Contract.from_abi("IotexRedeem", redeem_proxy.address, IotexRedeem.abi)

    transparent_stIOTX.initialize(
            {'from': owner, 'gas': GAS_LIMIT}
            )

    transparent_stIOTX.setMintable(
            transparent_staking, True,
            {'from': owner, 'gas': GAS_LIMIT}
            )

    transparent_staking.initialize(
            {'from': owner, 'gas': GAS_LIMIT}
            ) 

    transparent_staking.setStIOTXContractAddress(
            transparent_stIOTX,
            {'from': owner, 'gas': GAS_LIMIT}
            )

    transparent_staking.setRedeemContract(
            transparent_redeem,
            {'from': owner, 'gas': GAS_LIMIT}
            )


