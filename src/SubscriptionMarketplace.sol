// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// Custom
import { ISubscriptionMarketplace } from "./interfaces/ISubscriptionMarketplace.sol";
import { AggregatorV3Interface } from "./interfaces/AggregatorV3Interface.sol";
// import { FeeValidation } from "./utils/FeeValidation.sol";

/**
 * REQUIREMENTS:
 *
 * PROVIDERS:
 *         - Providers can register via a registration key and fee ✅
 *         - Max providers = 200 ✅
 *         - Min fee = $50 via chainlink oracle ✅
 *         - When providers unregister themselves, they can withdraw their balance ❌
 *         - Providers could be in active or inactive state at any given point in time.
 *         Only owner of the contract can change the state of the provider. ✅
 *         - Providers can collect their earnings from the contract which is calculated based on the number
 *         of subscribers and the fee of the provider ❌
 *             o When doing this emit an event (tokenWithdrawn, USDValueOfToken)
 *
 *     SUBSCRIBERS:
 *         - Subscribers can register with more than 1 providers ✅
 *         - They must deposit a minimum deposit amt of $100 equivalent (via chainlink oracle) ✅
 *         - The deposit amount must be greater than the sum of the fees of the providers they are subscribing to ✅
 *
 *     Other requirements:
 *         - Contract is upgradeable with feature of going non-upgradeable later ✅
 *         - Authorization checks are required ✅
 */
contract SubscriptionMarketplace is Initializable, OwnableUpgradeable, UUPSUpgradeable, ISubscriptionMarketplace {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_PROVIDERS = 200;
    uint256 private constant MIN_FEE = 50e8;
    uint256 private constant MIN_DEPOSIT = 100e8;

    bytes32 private constant SUBSCRIPTION_MARKETPLACE_STORAGE_SLOT =
        0xdd053ef5b7dcb9ec05b80ff2637f42f6ef9de2a843e2cb084f8c761cbaa21d00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _weth) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        _getStorage().WETH = IERC20(_weth);
    }

    struct SubscriptionMarketplaceStorage {
        AggregatorV3Interface priceFeed;
        IERC20 WETH;
        // Core entity storage
        mapping(uint256 providerId => Provider) providers;
        mapping(uint256 subscriberId => Subscriber) subscribers;
        // Double mapping for O(1) lookups
        mapping(uint256 providerId => EnumerableSet.UintSet) providerSubscribers;
        mapping(uint256 subscriberId => EnumerableSet.UintSet) subscriberProviders;
        // Registry mappings
        mapping(address providerOwner => uint256) ownerToProviderId;
        mapping(address subscriberOwner => uint256) ownerToSubscriberId;
        mapping(bytes32 registrationKey => bool) usedRegistrationKey;
        // Counter for IDs
        uint256 nextProviderId;
        uint256 nextSubscriberId;
        uint256 totalProviders;
    }

    function registerProvider(bytes32 registrationKey, uint256 fee) external returns (uint256) {
        SubscriptionMarketplaceStorage storage $ = _getStorage();

        // Validation
        if ($.usedRegistrationKey[registrationKey]) revert RegistrationKeyAlreadyUsed(registrationKey);
        if (!_isValidProviderFee(fee)) revert InvalidProviderFee(fee);
        if ($.ownerToProviderId[msg.sender] != 0) revert ProviderAlreadyRegistered(msg.sender);
        if ($.totalProviders >= MAX_PROVIDERS) revert MaxProvidersReached();

        // State changes
        $.usedRegistrationKey[registrationKey] = true;
        uint256 providerId = _generateProviderId();
        $.providers[providerId] = Provider({ owner: msg.sender, fee: fee, isActive: true });
        $.ownerToProviderId[msg.sender] = providerId;
        $.totalProviders++;

        // Events
        emit ProviderRegistered(providerId, msg.sender, fee);

        return providerId;
    }

    /**
     * @notice Register a subscriber with one or more providers
     * @param providers The array of provider IDs
     * @param depositAmt The amount of deposit in WETH
     * @return subscriberId The ID of the registered subscriber
     */
    function registerSubscriber(uint256[] calldata providers, uint256 depositAmt) external returns (uint256) {
        SubscriptionMarketplaceStorage storage $ = _getStorage();

        address msgSender = _msgSender();
        // Validation
        if (!_isValidSubscriberDeposit(depositAmt)) revert InvalidSubscriberDeposit(depositAmt);
        if ($.ownerToSubscriberId[msgSender] != 0) revert SubscriberAlreadyRegistered(msgSender);
        if (providers.length > MAX_PROVIDERS) revert MaxProvidersReached();

        uint256 subscriberId = _generateSubscriberId();
        uint256 requiredDeposit = 0;
        uint256 providerLength = providers.length;

        for (uint256 i = 0; i < providerLength;) {
            uint256 providerId = providers[i];
            Provider memory provider = $.providers[providerId];
            if (!provider.isActive) revert ProviderNotActive(providerId);
            // State changes
            requiredDeposit += provider.fee;
            $.providerSubscribers[providerId].add(subscriberId);
            $.subscriberProviders[subscriberId].add(providerId);

            unchecked {
                ++i;
            }
        }

        if (depositAmt < requiredDeposit) revert InsufficientDeposit(depositAmt, requiredDeposit);
        // Transfer funds to the contract
        $.WETH.safeTransferFrom(msgSender, address(this), depositAmt);

        // Store the subscriber details
        $.subscribers[subscriberId] =
            Subscriber({ owner: msgSender, balance: depositAmt, registrationTime: block.timestamp });
        $.ownerToSubscriberId[msgSender] = subscriberId;

        // Events
        emit SubscriberRegistered(subscriberId, msgSender, depositAmt);

        return subscriberId;
    }

    function unregisterProvider(uint256 providerId) external {
        SubscriptionMarketplaceStorage storage $ = _getStorage();
        if ($.ownerToProviderId[msg.sender] != providerId) revert Unauthorized();
        $.providers[providerId].isActive = false;

        emit ProviderUnregistered(providerId, msg.sender);
    }

    function deactivateProvider(uint256 providerId) external onlyOwner {
        SubscriptionMarketplaceStorage storage $ = _getStorage();
        $.providers[providerId].isActive = false;
    }

    function subscribe(uint256 providerId, uint256 depositAmt) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function unsubscribe(uint256 providerId) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function collectEarnings() external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    // Getters
    function getProvider(uint256 providerId) external view returns (uint256, uint256, bool) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function getSubscriber(uint256 subscriberId) external view returns (uint256, uint256, uint256, bool) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function getProviderBalance(uint256 providerId) external view returns (uint256) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function getProviderEarnings(uint256 providerId) external view returns (uint256) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function getSubscriberBalance(uint256 subscriberId) external view returns (uint256) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function getSubscriberDepositValueUSD(uint256 subscriberId) external view returns (uint256) {
        // TODO: Implement
        revert("Not implemented yet");
    }

    ////////////////////////////////////////////////////////
    ///////////////// VIEW FUNCTIONS //////////////////////
    ////////////////////////////////////////////////////////

    function getUSDValueOfToken() public view returns (uint256) {
        (
            /* uint80 roundId */
            ,
            int256 answer,
            /*uint256 startedAt*/
            ,
            /*uint256 updatedAt*/
            ,
            /*uint80 answeredInRound*/
        ) = AggregatorV3Interface(_getStorage().priceFeed).latestRoundData();
        uint256 price = uint256(answer);
        // returns in 8 decimals
        return price;
    }

    /// @dev Returns the USD value of a token in 8 decimals
    function getUSDValueOfToken(uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, getUSDValueOfToken(), 10 ** 18);
    }

    ////////////////////////////////////////////////////////
    ////////////// INTERNAL/PRIVATE FUNCTIONS //////////////
    ////////////////////////////////////////////////////////

    function _isValidProviderFee(uint256 _fee) internal view returns (bool) {
        return (_fee * getUSDValueOfToken(_fee)) >= MIN_FEE;
    }

    function _isValidSubscriberDeposit(uint256 _deposit) internal view returns (bool) {
        return (_deposit * getUSDValueOfToken(_deposit)) >= MIN_DEPOSIT;
    }

    function _generateProviderId() private returns (uint256) {
        return _getStorage().nextProviderId++;
    }

    function _generateSubscriberId() private returns (uint256) {
        return _getStorage().nextSubscriberId++;
    }

    function _getStorage() private pure returns (SubscriptionMarketplaceStorage storage $) {
        assembly {
            $.slot := SUBSCRIPTION_MARKETPLACE_STORAGE_SLOT
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
