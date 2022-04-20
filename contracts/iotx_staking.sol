// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IMintableContract is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract IOTEXStaking is Initializable, PausableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address payable;
    using Address for address;
    
    // track debts to return to async caller
    struct Debt {
        address account;
        uint256 amount;
    }

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 private constant MULTIPLIER = 1e18; 

    // Always extend storage instead of modifying it
    // Variables in implementation v0 
    address public stIOTXAddress;           // token address
    uint256 public managerFeeShare;         // manager's fee in 1/1000
    
    // known node credentials, pushed by owner
    bytes [] validatorRegistry;
    uint256 public nextValidatorIdx;

    // FIFO of debts from redeem
    mapping(uint256=>Debt) private debts;
    uint256 private firstDebt;
    uint256 private lastDebt;
    mapping(address=>uint256) private userDebts;    // debts from user's perspective

    // accounting
    uint256 public totalBalance;
    uint256 public totalPending;
    uint256 public totalDebts;
    
    uint256 private tslastPayDebt;      // record timestamp of last payDebts

    /** 
     * ======================================================================================
     * 
     * SYSTEM SETTINGS, OPERATED VIA OWNER(DAO/TIMELOCK)
     * 
     * ======================================================================================
     */

    /**
     * @dev receive revenue
     */
    receive() external payable {
        emit RewardReceived(msg.value);
    }

    /**
     * @dev pause the contract
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev unpause the contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev initialization address
     */
    function initialize() initializer public {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        // init default values
        firstDebt = 1;
        lastDebt = 0;
    }

    /**
     * @dev register a validator
     */
    function registerValidator(bytes calldata pubkey) external onlyRole(OPERATOR_ROLE) {
        validatorRegistry.push(pubkey);
    }

    /**
     * @dev set stIOTEX token contract address
     */
    function setStIOTXContractAddress(address _address) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stIOTXAddress = _address;

        emit STIOTXContractSet(stIOTXAddress);
    }

    /**
     * @dev pull pending revenue
     */
    function pullPending(address account) external nonReentrant onlyRole(OPERATOR_ROLE) {
        payable(account).sendValue(totalPending);
        totalBalance += totalPending;
        totalPending = 0;
        
        emit Pull(account, totalPending);
    }

    /**
     * @dev push balance from validators
     */
    function pushBalance(uint256 latestBalance) external onlyRole(ORACLE_ROLE) {
        require(latestBalance >= _totalIOTX(), "REPORTED_LESS_BALANCE");
        require(block.timestamp > tslastPayDebt, "EXPIRED_BALANCE_PUSH");
        totalBalance = latestBalance;

        emit BalancePushed(latestBalance);
    }

    /**
     * @dev payDebts
     */
    function payDebts() external payable nonReentrant onlyRole(OPERATOR_ROLE) {
        // record timestamp to avoid expired pushBalance transaction
        tslastPayDebt = block.timestamp;

        // iotx to pay
        uint256 iotxPayable = msg.value;
        uint256 paied;
        for (uint i=firstDebt;i<=lastDebt;i++) {
            if (iotxPayable == 0) {
                break;
            }

            Debt storage debt = debts[i];

            // clean debts
            uint256 toPay = debt.amount <= iotxPayable? debt.amount:iotxPayable;
            debt.amount -= toPay;
            iotxPayable -= toPay;
            paied += toPay;
            userDebts[debt.account] -=toPay;

            // money transfer
            payable(debt.account).sendValue(toPay);

            // log
            emit DebtPaid(debt.account, debt.amount);

            // untrack 
            if (debt.amount == 0) {
                _dequeueDebt();
            }
        }

        // track total debts
        totalDebts -= paied;
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */

    /**
     * @dev return debt for an account
     */
    function debtOf(address account) external view returns (uint256) {
        return userDebts[account];
    }

    /**
     * @dev return debt of index
     */
    function checkDebt(uint256 index) external view returns (address account, uint256 amount) {
        Debt memory debt = debts[index];
        return (debt.account, debt.amount);
    }

    /**
     * @dev return debt queue index
     */
    function getDebtQueue() external view returns (uint256 first, uint256 last) {
        return (firstDebt, lastDebt);
    }
    /**
     * @dev return exchange ratio of xETH:ETH, multiplied by 1e18
     */
    function exchangeRatio() external view returns (uint256) {
        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        if (totalST == 0) {
            return 1 * MULTIPLIER;
        }

        uint256 ratio = _totalIOTX() * MULTIPLIER / totalST;
        return ratio;
    }

 
     /**
     * ======================================================================================
     * 
     * EXTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    /**
     * @dev mint stIOTX with IOTX
     */
    function mint() external payable nonReentrant whenNotPaused {
         // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);
        require(msg.value > 0, "MINT_ZERO");

        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 toMint = msg.value;  // default exchange ratio 1:1
        uint256 totalIOTX = _totalIOTX();
        if (totalIOTX > 0) { // avert division overflow
            toMint = totalST * msg.value / totalIOTX;
        }
        
        // sum total pending IOTX
        totalPending += msg.value;

        // mint stIOTX
        IMintableContract(stIOTXAddress).mint(msg.sender, toMint);

        // log 
        emit Mint(msg.sender, msg.value);
    }

    /**
     * @dev redeem IOTX via stIOTX
     * given number of stIOTX expected to burn
     */
    function redeem(uint256 stIOTXToBurn) external nonReentrant {
         // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);

        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 iotxToRedeem = _totalIOTX() * stIOTXToBurn / totalST;

        // track IOTX debts
        _enqueueDebt(msg.sender, iotxToRedeem);
        userDebts[msg.sender] += iotxToRedeem;
        totalDebts += iotxToRedeem;

        // transfer stIOTX from sender & burn
        IERC20(stIOTXAddress).safeTransferFrom(msg.sender, address(this), stIOTXToBurn);
        IMintableContract(stIOTXAddress).burn(stIOTXToBurn);

        // emit amount withdrawed
        emit Redeem(msg.sender, iotxToRedeem);
    }

    /**
     * @dev redeem IOTX via stIOTX
     * given number of IOTX expected to receive
     */
    function redeemUnderlying(uint256 iotxToRedeem) external nonReentrant {
         // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);

        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 stIOTXToBurn = totalST * iotxToRedeem / _totalIOTX();

        // track IOTX debts
        _enqueueDebt(msg.sender, iotxToRedeem);
        userDebts[msg.sender] += iotxToRedeem;
        totalDebts += iotxToRedeem;

        // transfer stIOTX from sender & burn
        IERC20(stIOTXAddress).safeTransferFrom(msg.sender, address(this), stIOTXToBurn);
        IMintableContract(stIOTXAddress).burn(stIOTXToBurn);

        // emit amount withdrawed
        emit Redeem(msg.sender, iotxToRedeem);
    }

    /** 
     * ======================================================================================
     * 
     * INTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    function _enqueueDebt(address account, uint256 amount) internal {
        lastDebt += 1;
        debts[lastDebt] = Debt({account:account, amount:amount});
    }

    function _dequeueDebt() internal returns (Debt memory debt) {
        require(lastDebt >= firstDebt);  // non-empty queue
        debt = debts[firstDebt];
        delete debts[firstDebt];
        firstDebt += 1;
    }
    
    function _totalIOTX() internal view returns(uint256) {
        return totalBalance + totalPending - totalDebts;
    }

    /**
     * ======================================================================================
     * 
     * STAKING EVENTS
     *
     * ======================================================================================
     */
    event RewardReceived(uint256 amount);
    event Mint(address account, uint256 amountIOTX);
    event STIOTXContractSet(address addr);
    event Pull(address account, uint256 totalPending);
    event Redeem(address account, uint256 amountIOTX);
    event DebtPaid(address creditor, uint256 amount);
    event BalancePushed(uint256 balance);
}