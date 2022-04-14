from brownie import *
from pathlib import Path

def main():
    deps = project.load(  Path.home() / ".brownie" / "packages" / config["dependencies"][0])
    TransparentUpgradeableProxy = deps.TransparentUpgradeableProxy

    owner = accounts[0]
    deployer = accounts[1]
    print(f'contract owner account: {owner.address}\n')

    stIOTEX_contract = stIOTEX.deploy(
            {'from': deployer}
            )

    stIOTEX_proxy = TransparentUpgradeableProxy.deploy(
            stIOTEX_contract, deployer, b'',
            {'from': deployer}
            )


