from brownie import *
from pathlib import Path

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

    transparent_stIOTX= Contract.from_abi("stIOTX", stIOTX_proxy.address, stIOTX.abi)
    transparent_staking = Contract.from_abi("IOTEXStaking", iotexStaking_proxy.address, IOTEXStaking.abi)


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

    transparent_staking.registerValidator(b'1234', {'from':accounts[0]})
    print(transparent_staking.exchangeRatio(), transparent_stIOTX.balanceOf(accounts[0]))
    transparent_staking.mint(0, {'from':accounts[0], 'value':'1 ether'})
    print(transparent_staking.exchangeRatio(), transparent_stIOTX.balanceOf(accounts[0]))
    transparent_staking.pullPending(accounts[0], {'from':accounts[0]})
    print(transparent_staking.exchangeRatio())
    transparent_staking.pushBalance('1.1 ether', {'from':accounts[0]})
    print("ratio:", transparent_staking.exchangeRatio())
    transparent_stIOTX.approve(transparent_staking, '1000000 ether', {'from':accounts[0]})
    transparent_staking.redeemUnderlying('0.5 ether', {'from':accounts[0]})
    print("ratio:", transparent_staking.exchangeRatio(), "debt:",transparent_staking.debtOf(accounts[0]))
    transparent_staking.payDebts({'from':accounts[0], 'value':'0.55 ether'})
    print("ratio:", transparent_staking.exchangeRatio(), "debt:",transparent_staking.debtOf(accounts[0]))
    transparent_staking.pushBalance('0.56 ether', {'from':accounts[0]})
    print("ratio:", transparent_staking.exchangeRatio())

