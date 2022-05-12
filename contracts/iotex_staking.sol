// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "interfaces/interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


/**
 * @notice IOTEXStaking Contract
 *
 * IOTEXStaking is decide to mining on IOTEX network, investors deposits their IOTEX token to this contract,
 * and receives constantly increase revenue.
 */
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
    address public redeemContract;          // redeeming contract for user to pull iotex
    
    // track revenue from validators to form exchange ratio
    uint256 private accountedUserRevenue;    // accounted shared user revenue
    uint256 private accountedManagerRevenue; // accounted manager's revenue
    
    // known node credentials, pushed by owner
    bytes [] private validatorRegistry;
    uint256 public validatorIdx;

    // FIFO of debts from redeem
    mapping(uint256=>Debt) private debts;
    uint256 private firstDebt;
    uint256 private lastDebt;
    mapping(address=>uint256) private userDebts;    // debts from user's perspective

    // Accounting
    //  Revenue := latestBalance - reportedBalanceSnapshot
    //  ManagerFee := Revenue * managerFeeShare / 1000
    uint256 private reportedBalanceSnapshot;
    uint256 private totalPending;            // prepend
    uint256 private totalDebts;
    uint256 private unstakedValue;

    // these variables below are used to track the exchange ratio
    uint256 private accDeposited;           // track accumulated deposited iotex from users
    uint256 private accWithdrawed;          // track accumulated withdrawed iotex from users

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
        managerFeeShare = 5;
    }

    /**
     * @dev set redeem contract
     */
    function setRedeemContract(address _redeemContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redeemContract = _redeemContract;

        emit RedeemContractSet(_redeemContract);
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
     * @dev pull pending iotex to stake
     */
    function pullPending(address account) external nonReentrant onlyRole(OPERATOR_ROLE) {
        payable(account).sendValue(totalPending);

        // rebase balance
        reportedBalanceSnapshot += totalPending;

        // select validator for this pull
        bytes memory vid = getNextValidatorId();

        // round-robin strategy
        validatorIdx++;

        // emit a log to a specific valiator
        emit Pull(account, totalPending, vid);

        // track total deposited
        accDeposited += totalPending;

        // reset total pending
        totalPending = 0; 
    }

    /**
     * @dev withdraw manager revenue 
     */
    function withdrawRevenue(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(to).sendValue(accountedManagerRevenue);
        emit RevenueWithdrawed(to, accountedManagerRevenue);
        accountedManagerRevenue = 0;
    }

    /**
     * @dev push balance from validators
     */
    function pushBalance(uint256 latestBalance) external onlyRole(ORACLE_ROLE) {
        require(latestBalance + unstakedValue >= _totalIOTX(), "REPORTED_LESS_BALANCE");

        // If revenue generated, the excessive part compared to last balance snapshot 
        //  is the total revenue for both user & manager.
        //
        // NOTE(f):
        //  If some user redeems, the latestBalance will be smaller than reportedBalanceSnapshot
        //  so we need to take unstakedValue during latest payDebts() into account.
        if (latestBalance + unstakedValue > reportedBalanceSnapshot) { 
            _distributeRevenue(latestBalance + unstakedValue - reportedBalanceSnapshot);
        }

        // update to latest balance snapshot
        reportedBalanceSnapshot = latestBalance;
        unstakedValue = 0;
    }

    /**
     * @dev pay debts to those who redeems
     */
    function payDebts() external payable nonReentrant onlyRole(OPERATOR_ROLE) {
        // track total debts
        uint256 paid = _payDebts(msg.value);
        // record value decrease
        unstakedValue += msg.value;
        // return extra value back to totalPending
        totalPending += msg.value - paid;
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */
    /**
     * @dev return accumulated deposited iotex
     */
    function getAccumulatedDeposited() external view returns (uint256) { return  accDeposited; }

    /**
     * @dev return accumulated withdrawed iotex
     */
    function getAccumulatedWithdrawed() external view returns (uint256) { return  accWithdrawed; }
    
    /**
     * @dev get pending iotex
     */
    function getPendings() external view returns (uint256) { return totalPending; }

    /**
     * @dev return current unpaid debts
     */
    function getCurrentDebts() external view returns (uint256) { return totalDebts; }

    /**
     * @dev return last balance report snapshot
     */
    function getReportedValidatorBalance() external view returns (uint256) { return reportedBalanceSnapshot; }

    /**
     * @dev return current unstaked value(should mainly be 0)
     */
    function getUnstakedValue() external view returns (uint256) { return unstakedValue; }

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
     * @dev return exchange ratio of stIOTX:IOTX, multiplied by 1e18
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
     * @dev return number of registered validator
     */
    function getRegisteredValidatorsCount() external view returns (uint256) {
        return validatorRegistry.length;
    }
    
    /**
     * @dev return a batch of validators credential
     */
    function getRegisteredValidators(uint256 idx_from, uint256 idx_to) external view returns (bytes [] memory validators) {
        validators = new bytes[](idx_to - idx_from);

        uint counter = 0;
        for (uint i = idx_from; i < idx_to;i++) {
            validators[counter] = validatorRegistry[i];
            counter++;
        }
    }

    /**
     * @dev return next validator
     */
    function getNextValidatorId() public view returns (bytes memory) {
        return validatorRegistry[validatorIdx%validatorRegistry.length];
    }

    /**
     * @dev returns the accounted user revenue
     */
    function getAccountedUserRevenue() external view returns (uint256) { return accountedUserRevenue; }

    /**
     * @dev returns the accounted manager's revenue
     */
    function getAccountedManagerRevenue() external view returns (uint256) { return accountedManagerRevenue; }
 
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
    function mint(uint256 minToMint) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "MINT_ZERO");

        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 toMint = msg.value;  // default exchange ratio 1:1
        uint256 totalIOTX = _totalIOTX();
        if (totalIOTX > 0) { // avert division overflow
            toMint = totalST * msg.value / totalIOTX;
        }
        // slippage control
        require(toMint > minToMint, "EXCEEDED_SLIPPAGE");

        // mint stIOTX
        IMintableContract(stIOTXAddress).mint(msg.sender, toMint);

        // pay debts in priority
        uint256 debtPaid = _payDebts(msg.value);
        uint256 remain = msg.value - debtPaid;

        if (remain > 0 ) {
            // sum total pending IOTX
            totalPending += remain;
            
            // log 
            emit Mint(msg.sender, msg.value);
        }
    }

    /**
     * @dev redeem IOTX via stIOTX
     * given number of stIOTX expected to burn
     */
    function redeem(uint256 stIOTXToBurn) external nonReentrant {
        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 iotxToRedeem = _totalIOTX() * stIOTXToBurn / totalST;

        // transfer stIOTX from sender & burn
        IERC20(stIOTXAddress).safeTransferFrom(msg.sender, address(this), stIOTXToBurn);
        IMintableContract(stIOTXAddress).burn(stIOTXToBurn);

        // queue debts
        _enqueueDebt(msg.sender, iotxToRedeem);

        // try to pay debts from swap pool
        totalPending -= _payDebts(totalPending);
        
        // emit amount withdrawed
        emit Redeem(msg.sender, iotxToRedeem);
    }

    /**
     * @dev redeem IOTX via stIOTX
     * given number of IOTX expected to receive
     */
    function redeemUnderlying(uint256 iotxToRedeem) external nonReentrant {
        uint256 totalST = IERC20(stIOTXAddress).totalSupply();
        uint256 stIOTXToBurn = totalST * iotxToRedeem / _totalIOTX();

        // transfer stIOTX from sender & burn
        IERC20(stIOTXAddress).safeTransferFrom(msg.sender, address(this), stIOTXToBurn);
        IMintableContract(stIOTXAddress).burn(stIOTXToBurn);

        // queue debts
        _enqueueDebt(msg.sender, iotxToRedeem);

        // try to pay debts from swap pool
        totalPending -= _payDebts(totalPending);

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

        // track user debts
        userDebts[account] += amount;
        // track total debts
        totalDebts += amount;

        // log
        emit DebtQueued(account, amount);
    }

    function _dequeueDebt() internal returns (Debt memory debt) {
        require(lastDebt >= firstDebt);  // non-empty queue
        debt = debts[firstDebt];
        delete debts[firstDebt];
        firstDebt += 1;
    }
    
    function _totalIOTX() internal view returns(uint256) {
        // (accDeposited - accWithdrawed) + accountedUserRevenue + totalPending - totalDebts;
        // reformed below to avert underflow
        return accDeposited  + accountedUserRevenue + totalPending - totalDebts - accWithdrawed;
    }

    /**
     * @dev distribute revenue based on balance
     */
    function _distributeRevenue(uint256 rewards) internal {
        // rewards distribution
        uint256 fee = rewards * managerFeeShare / 1000;
        accountedManagerRevenue += fee;
        accountedUserRevenue += rewards - fee;
        emit RevenueAccounted(rewards);
    }
    
    /**
     * @dev payDebts
     */
    function _payDebts(uint256 total) internal returns(uint256 amountPaied) {
        // iotx to pay
        uint256 iotxPayable = total;
        uint256 paid;
        for (uint i=firstDebt;i<=lastDebt;i++) {
            if (iotxPayable == 0) {
                break;
            }

            Debt storage debt = debts[i];

            // clean debts
            uint256 toPay = debt.amount <= iotxPayable? debt.amount:iotxPayable;
            debt.amount -= toPay;
            iotxPayable -= toPay;
            paid += toPay;
            userDebts[debt.account] -=toPay;

            // money transfer
            // transfer money to redeem contract
            IRedeem(redeemContract).pay{value:toPay}(debt.account);

            // log
            emit DebtPaid(debt.account, debt.amount);

            // untrack 
            if (debt.amount == 0) {
                _dequeueDebt();
            }
        }

        accWithdrawed += paid;
        totalDebts -= paid;
        return paid;
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
    event Pull(address account, uint256 totalPending, bytes vid);
    event Redeem(address account, uint256 amountIOTX);
    event DebtPaid(address creditor, uint256 amount);
    event DebtQueued(address creditor, uint256 amount);
    event RevenueAccounted(uint256 revenue);
    event RevenueWithdrawed(address to, uint256 revenue);
    event RedeemContractSet(address addr);
}