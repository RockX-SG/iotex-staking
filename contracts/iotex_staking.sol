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
    address public stIOTEXAddress;          // token address
    uint256 public managerFeeShare;         // manager's fee in 1/1000
    
    // known node credentials, pushed by owner
    mapping(bytes32 => bool) validatorRegistry;

    // FIFO of debts from redeem
    mapping(uint256=>Debt) private debts;
    uint256 private firstDebt;
    uint256 private lastDebt;

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
        bytes32 pubkeyHash = keccak256(pubkey);
        require(!validatorRegistry[pubkeyHash], "DUPLICATED_PUBKEY");
        validatorRegistry[pubkeyHash] = true;
    }

    /**
     * @dev set stIOTEX token contract address
     */
    function setStIOTEXContractAddress(address _address) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stIOTEXAddress = _address;

        emit STIOTEXContractSet(stIOTEXAddress);
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */

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
     * ======================================================================================
     * 
     * EXTERNAL FUNCTIONS
     * 
     * ======================================================================================
     */
    /**
     * @dev mint stIOTEX with IOTEX to a specific node
     */
    function mint(bytes32 pubkey) external payable nonReentrant whenNotPaused {
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

    /**
     * ======================================================================================
     * 
     * STAKING EVENTS
     *
     * ======================================================================================
     */
    event RewardReceived(uint256 amount);
    event STIOTEXContractSet(address addr);
}