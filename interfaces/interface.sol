// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableContract is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IIotexRedeem {
    function pay(address account) external payable;
    function claim(uint256 amount) external;
    function balanceOf(address account) external view returns(uint256);
}
