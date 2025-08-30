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
import { ISubscriptionService } from "./interfaces/ISubscriptionService.sol";
import { AggregatorV3Interface } from "./interfaces/AggregatorV3Interface.sol";
import { IWeth } from "./interfaces/IWeth.sol";
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
 *         - A subscription can be paused so that the subscriber is not charged by the provider ❌
 *         -
 *
 *     Other requirements:
 *         - Contract is upgradeable with feature of going non-upgradeable later ✅
 *         - Authorization checks are required ✅
 */
contract SubscriptionService is Initializable, OwnableUpgradeable, UUPSUpgradeable, ISubscriptionService {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant MAX_PROVIDERS = 200;
    uint256 private constant MIN_FEE = 50e8;
    uint256 private constant MIN_DEPOSIT = 100e8;
    uint256 private constant BILLING_PERIOD = 30 days;

    bytes32 private constant SUBSCRIPTION_SERVICE_STORAGE_SLOT =
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

    struct SubscriptionServiceStorage {
        AggregatorV3Interface priceFeed;
        IERC20 WETH;
        // Core entity storage
        mapping(uint256 providerId => Provider) providers;
        mapping(uint256 subscriberId => Subscriber) subscribers;
        // Double mapping for O(1) lookups
        mapping(uint256 providerId => EnumerableSet.UintSet) providerSubscribers;
        // mapping(uint256 subscriberId => EnumerableSet.UintSet) subscriberProviders;
        mapping(uint256 subscriberId => mapping(uint256 providerId => Subscription)) subscriptions;
        // Registry mappings
        mapping(address providerOwner => uint256) ownerToProviderId;
        mapping(address subscriberOwner => uint256) ownerToSubscriberId;
        mapping(bytes32 registrationKey => bool) usedRegistrationKey;
        // Counter for IDs
        uint256 nextProviderId;
        uint256 nextSubscriberId;
        uint256 totalProviders;
    }

    receive() external payable {
        if (_getStorage().ownerToSubscriberId[msg.sender] == 0) revert Unauthorized();
        SubscriptionServiceStorage storage $ = _getStorage();

        IWeth($.WETH).deposit{ value: msg.value }();
        $.subscribers[$.ownerToSubscriberId[msg.sender]].currentBalance += msg.value;
    }

    /**
     * @notice Register a provider with a given registration key and fee
     * @param registrationKey The registration key
     * @param fee The fee in WETH
     * @return providerId The ID of the registered provider
     */
    function registerProvider(bytes32 registrationKey, uint256 fee) external returns (uint256) {
        SubscriptionServiceStorage storage $ = _getStorage();
        address msgSender = _msgSender();
        // Validation
        if ($.usedRegistrationKey[registrationKey]) revert RegistrationKeyAlreadyUsed(registrationKey);
        if (!_isValidProviderFee(fee)) revert InvalidProviderFee(fee);
        if ($.ownerToProviderId[msgSender] != 0) revert ProviderAlreadyRegistered(msgSender);
        if ($.totalProviders >= MAX_PROVIDERS) revert MaxProvidersReached();

        // State changes
        $.usedRegistrationKey[registrationKey] = true;
        uint256 providerId = _generateProviderId();
        $.providers[providerId] = Provider({ owner: msgSender, fee: fee, isActive: true });
        $.ownerToProviderId[msgSender] = providerId;
        $.totalProviders++;

        // Events
        emit ProviderRegistered(providerId, msgSender, fee);

        return providerId;
    }

    /**
     * @notice Register a subscriber with one or more providers
     * @param providers The array of provider IDs
     * @param depositAmt The amount of deposit in WETH
     * @return subscriberId The ID of the registered subscriber
     */
    function registerSubscriber(uint256[] memory providers, uint256 depositAmt) external returns (uint256) {
        SubscriptionServiceStorage storage $ = _getStorage();

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
            $.subscriptions[subscriberId][providerId] = Subscription({
                startTs: uint48(block.timestamp),
                endTs: uint48(block.timestamp + 30 days),
                paused: false
            });

            unchecked {
                ++i;
            }
        }

        if (depositAmt < requiredDeposit) revert InsufficientDeposit(depositAmt, requiredDeposit);
        // Transfer funds to the contract
        $.WETH.safeTransferFrom(msgSender, address(this), depositAmt);

        // Store the subscriber details
        $.subscribers[subscriberId] = Subscriber({
            owner: msgSender,
            currentBalance: depositAmt - requiredDeposit,
            totalDeposits: depositAmt,
            registrationTime: block.timestamp
        });
        $.ownerToSubscriberId[msgSender] = subscriberId;

        // Events
        emit SubscriberRegistered(subscriberId, msgSender, depositAmt);

        return subscriberId;
    }

    /**
     * @notice Calculate the earnings of a provider
     * @param providerId The ID of the provider
     * @return totalEarnings The total earnings of the provider
     */
    function providerEarnings(uint256 providerId) external view returns (uint256) {
        SubscriptionServiceStorage storage $ = _getStorage();
        /**
         * - Go through each subscription for the month and collect the earnings
         *         -
         */
        uint256[] memory subscriberIds = $.providerSubscribers[providerId].values();

        uint256 totalEarnings = 0;

        for (uint256 i = 0; i < subscriberIds.length; i++) {
            uint256 subscriberId = subscriberIds[i];
            Subscription memory subscription = $.subscriptions[subscriberId][providerId];

            // last billed time to now, how many 30 days have passed
            uint256 monthsPassed = (block.timestamp - subscription.lastCollectedTs) / 30 days;
            if (monthsPassed > 0) {
                totalEarnings += monthsPassed * $.providers[providerId].fee;
                uint256 userBalance = $.subscribers[subscriberId].currentBalance;
                if (userBalance < totalEarnings) {
                    // proportional distribution
                    totalEarnings = (totalEarning / userBalance) * totaEarnings;
                }
            }
        }

        return totalEarnings;
    }

    function collectEarnings(uint256 providerId) external {
        SubscriptionServiceStorage storage $ = _getStorage();
        if ($.providers[providerId].owner != _msgSender()) revert Unauthorized();
        uint256[] memory subscriberIds = $.providerSubscribers[providerId].values();

        uint256 totalEarnings = 0;

        // Go through each subscription and calculate the earnings
        for (uint256 i = 0; i < subscriberIds.length; i++) {
            uint256 subscriberId = subscriberIds[i];
            Subscription storage subscription = $.subscriptions[subscriberId][providerId];

            // Doing ceiling division because we collect at the start of the billing period, so if
            // 1.5 months passed, we should collect for 2 months
            int256 monthsPassed = Math.ceilDiv(block.timestamp - subscription.lastCollectedTs, BILLING_PERIOD);

            if (monthsPassed > 0) {
                totalEarnings += monthsPassed * $.providers[providerId].fee;
                uint256 userBalance = $.subscribers[subscriberId].currentBalance;
                if (userBalance < totalEarnings) {
                    // proportional distribution
                    totalEarnings = (totalEarnings / userBalance) * totaEarnings;
                    subscription.paused = true;
                }
                // pasuse the subscription because the user doesn't have enough to cover for the ongoing month
                subscription.lastBillingTs += uint48(monthsPassed * BILLING_PERIOD);
            } else if (monthsPassed == 0) {
                // User hasn't paid for the current month, collect the fee
                totalEarnings += $.providers[providerId].fee;
                subscription.lastBillingTs += uint48(BILLING_PERIOD);
            } else {
                // User has paid for the current month, move to next subscriber
                continue;
            }
        }

        $.WETH.safeTransfer(msgSender, totalEarnings);
        // emit event with usd value [REQUIREMENT]
    }

    /**
     * @notice Increase the deposit of a subscriber
     * @param subscriberId The ID of the subscriber
     * @param depositAmt The amount of deposit in WETH
     */
    function increaseDeposit(uint256 subscriberId, uint256 depositAmt) external {
        SubscriptionServiceStorage storage $ = _getStorage();
        if ($.subscribers[subscriberId].owner != _msgSender()) revert Unauthorized();
        if (!_isValidSubscriberDeposit(depositAmt)) revert InvalidSubscriberDeposit(depositAmt);

        $.subscribers[subscriberId].totalDeposits += depositAmt;
        $.subscribers[subscriberId].currentBalance += depositAmt;
        $.WETH.safeTransferFrom(msgSender, address(this), depositAmt);

        emit DepositIncreased(subscriberId, msgSender, depositAmt);
    }

    /**
     * @notice Check if a subscription is paused
     * @param subscriberId The ID of the subscriber
     * @param providerId The ID of the provider
     * @return True if the subscription is paused, false otherwise
     */
    function isSubscriptionPaused(uint256 subscriberId, uint256 providerId) external view returns (bool) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.subscriptions[subscriberId][providerId].paused;
    }

    /**
     * @notice Unregister a provider
     * @param providerId The ID of the provider
     */
    function unregisterProvider(uint256 providerId) external {
        SubscriptionServiceStorage storage $ = _getStorage();
        address msgSender = _msgSender();
        if ($.ownerToProviderId[msgSender] != providerId) revert Unauthorized();
        $.providers[providerId].isActive = false;

        emit ProviderUnregistered(providerId, msgSender);
    }

    /**
     * @notice Deactivate a provider
     * @param providerId The ID of the provider
     */
    function changeProvideStatus(uint256 providerId) external onlyOwner {
        SubscriptionServiceStorage storage $ = _getStorage();
        if ($.providers[providerId].owner == address(0)) revert ProviderNotRegistered(providerId);

        bool status = $.providers[providerId].isActive;
        $.providers[providerId].isActive = !status;

        emit ProviderStatusChanged(providerId, status);
    }

    function subscribe(uint256 providerId, uint256 depositAmt) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function unsubscribe(uint256 providerId) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function resumeSubscription(uint256 subscriberId, uint256 providerId) external {
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

    /// @notice Returns the USD value of the subscriber's total deposit
    function getSubscriberDepositValueUSD(uint256 subscriberId) external view returns (uint256) {
        return getUSDValueOfToken(_getStorage().subscribers[subscriberId].totalDeposits);
    }

    /**
     * @notice Returns the data of a provider
     * @param providerId The ID of the provider
     * @return subscriberCount The number of subscribers
     * @return fee The fee of the provider
     * @return owner The owner of the provider
     * @return balance The balance of the provider
     * @return isActive The status of the provider
     */
    function getProviderData(uint256 providerId) external view returns (uint256, uint256, address, uint256, bool) {
        SubscriptionServiceStorage storage $ = _getStorage();
        Provider memory provider = $.providers[providerId];

        return (
            $.providerSubscribers[providerId].length(),
            provider.fee,
            provider.owner,
            provider.balance,
            provider.isActive
        );
    }

    function getSubscriberData(uint256 subscriberId) external view returns (address, uint256) {
        // Returns owner, balance, plan and state
        SubscriptionServiceStorage storage $ = _getStorage();
        Subscriber memory subscriber = $.subscribers[subscriberId];

        return (subscriber.owner, subscriber.currentBalance);
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

    function _getStorage() private pure returns (SubscriptionServiceStorage storage $) {
        assembly {
            $.slot := SUBSCRIPTION_SERVICE_STORAGE_SLOT
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
