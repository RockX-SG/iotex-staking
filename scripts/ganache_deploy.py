from brownie import *
from pathlib import Path
import time

GAS_LIMIT = 6721975

def main():
    deps = project.load(  Path.home() / ".brownie" / "packages" / config["dependencies"][0])
    TransparentUpgradeableProxy = deps.TransparentUpgradeableProxy

    owner = accounts[0]
    deployer = accounts[1]
    print(f'contract owner account: {owner.address}\n')

    stIOTX_contract = stIOTX.deploy(
            {'from': deployer}
            )

    stIOTX_proxy = TransparentUpgradeableProxy.deploy(
            stIOTX_contract, deployer, b'',
            {'from': deployer}
            )

    iotexStaking_contract = IOTEXStaking.deploy(
            {'from': deployer}
            )

    iotexStaking_proxy = TransparentUpgradeableProxy.deploy(
            iotexStaking_contract, deployer, b'',
            {'from': deployer}
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

    # init
    print(transparent_staking.exchangeRatio(), transparent_stIOTX.balanceOf(owner))
    transparent_staking.mint(0, time.time() + 600, {'from':owner, 'value':'1 ethers'})
    print("balance+ratio:", transparent_staking.exchangeRatio(), transparent_stIOTX.balanceOf(owner))
    transparent_staking.pullPending(owner, {'from':accounts[0]})
    print("ratio:", transparent_staking.exchangeRatio())
    transparent_staking.pushBalance('1.1 ethers', {'from':owner})
    print("ratio:", transparent_staking.exchangeRatio())
    transparent_stIOTX.approve(transparent_staking, '1000000 ethers', {'from':owner})
    print("balance+allowance:", transparent_stIOTX.balanceOf(owner), transparent_stIOTX.allowance(owner, transparent_staking.address))
    transparent_staking.redeem('0.5 ethers',0, time.time() + 600, {'from':owner})
    transparent_staking.redeemUnderlying('0.5 ethers', '100 ethers', time.time() + 600, {'from':owner})
    print("ratio:", transparent_staking.exchangeRatio(), "debt:",transparent_staking.debtOf(owner))
    transparent_staking.payDebts({'from':owner, 'value':'0.55 ethers'})
    print("ratio:", transparent_staking.exchangeRatio(), "debt:",transparent_staking.debtOf(owner))
    transparent_staking.pushBalance('0.55 ethers', {'from':owner})
    print("ratio:", transparent_staking.exchangeRatio())
    print("redeem balance before:", transparent_redeem.balanceOf(owner))
    transparent_redeem.claim(transparent_redeem.balanceOf(owner),{'from':accounts[0]})
    print("redeem balance after:", transparent_redeem.balanceOf(owner))

