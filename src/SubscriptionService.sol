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

/**
 * REQUIREMENTS:
 *
 * PROVIDERS:
 *         - Providers can register via a registration key and fee ✅
 *         - Max providers = 200 ✅
 *         - Min fee = $50 via chainlink oracle ✅
 *         - When providers unregister themselves, they can withdraw their balance ✅
 *         - Providers could be in active or inactive state at any given point in time.
 *         Only owner of the contract can change the state of the provider. ✅
 *         - Providers can collect their earnings from the contract which is calculated based on the number
 *         of subscribers and the fee of the provider ✅
 *             o When doing this emit an event (tokenWithdrawn, USDValueOfToken)
 *
 *     SUBSCRIBERS:
 *         - Subscribers can register with more than 1 providers ✅
 *         - They must deposit a minimum deposit amt of $100 equivalent (via chainlink oracle) ✅
 *         - The deposit amount must be greater than the sum of the fees of the providers they are subscribing to ✅
 *         - A subscription can be paused so that the subscriber is not charged by the provider ✅
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

    /// @dev Storage slot for SubscriptionService storage
    /// @dev keccak256(abi.encode(uint256(keccak256("SubscriptionService.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SUBSCRIPTION_SERVICE_STORAGE_SLOT =
        0x65fa53bd38b9deaae3a51565dfc853a8ab4d049ba1b3221def634ed38fefda00;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyProvider(uint256 providerId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        if (!_isValidProvider(providerId)) revert Unauthorized();
        _;
    }

    modifier onlySubscriber(uint256 subscriberId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        if (!_isValidSubscriber(subscriberId)) revert Unauthorized();
        _;
    }

    function initialize(address _owner, address _weth, address _priceFeed) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        SubscriptionServiceStorage storage $ = _getStorage();
        $.WETH = IERC20(_weth);
        $.priceFeed = AggregatorV3Interface(_priceFeed);
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

        IWeth(address($.WETH)).deposit{ value: msg.value }();
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
        $.providers[providerId] = Provider({ owner: msgSender, fee: fee, balance: 0, isActive: true });
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
            if (requiredDeposit > depositAmt) revert InsufficientDeposit(depositAmt, requiredDeposit);

            $.providerSubscribers[providerId].add(subscriberId);
            $.providers[providerId].balance += provider.fee;
            $.subscriptions[subscriberId][providerId] = Subscription({
                startTime: uint48(block.timestamp),
                endTime: uint48(block.timestamp + BILLING_PERIOD),
                pausedAt: 0,
                paused: false
            });

            unchecked {
                ++i;
            }
        }

        // Transfer funds to the contract
        $.WETH.safeTransferFrom(msgSender, address(this), depositAmt);

        // Store the subscriber details
        $.subscribers[subscriberId] =
            Subscriber({ owner: msgSender, currentBalance: depositAmt - requiredDeposit, totalDeposits: depositAmt });
        $.ownerToSubscriberId[msgSender] = subscriberId;

        // Events
        emit SubscriberRegistered(subscriberId, msgSender, depositAmt);

        return subscriberId;
    }

    /**
     * @notice Collect the earnings of a provider from all active subscriptions
     * @dev This function is supposed to be called every month by the providers, if they don't call then
     * there may be a chance that they lose their earnings for the month they didn't charged.
     * @param providerId The ID of the provider
     */
    function processAllSubscriptions(uint256 providerId) public onlyProvider(providerId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        uint256[] memory subscriberIds = $.providerSubscribers[providerId].values();
        uint256 providerFee = $.providers[providerId].fee;

        if (subscriberIds.length == 0) {
            emit SubscriptionsProcesses(providerId, 0);
            return;
        }

        uint256 totalEarnings = 0;
        uint256 currentTime = block.timestamp;

        // Process each subscription to calculate earnings
        for (uint256 i = 0; i < subscriberIds.length;) {
            uint256 subscriberId = subscriberIds[i];
            if (!_isValidSubscription(subscriberId, providerId)) continue;

            totalEarnings += _processSubscriptionEarnings(subscriberId, providerId, providerFee, currentTime);

            unchecked {
                ++i;
            }
        }

        if (totalEarnings > 0) {
            $.providers[providerId].balance += totalEarnings;
        }

        emit SubscriptionsProcesses(providerId, totalEarnings);
    }

    /**
     * @notice Process a specific subscription and collect earnings
     * @dev Processes billing for a single subscriber-provider relationship
     * @param subscriberId The ID of the subscriber
     * @param providerId The ID of the provider
     */
    function processSubscription(uint256 subscriberId, uint256 providerId) public onlyProvider(providerId) {
        SubscriptionServiceStorage storage $ = _getStorage();

        // Validate that the subscription exists
        if (!_isValidSubscription(subscriberId, providerId)) revert InvalidSubscription(subscriberId, providerId);

        uint256 providerFee = $.providers[providerId].fee;
        uint256 currentTime = block.timestamp;

        // Process the single subscription
        uint256 earnings = _processSubscriptionEarnings(subscriberId, providerId, providerFee, currentTime);

        // Update provider balance if earnings were collected
        if (earnings > 0) {
            $.providers[providerId].balance += earnings;
        }

        emit SubscriptionsProcesses(providerId, earnings);
    }

    /**
     * @notice Collect earnings from a batch of subscribers for a provider
     * @dev This function processes subscribers in batches to avoid gas limit issues
     * @param providerId The ID of the provider
     * @param startIndex The starting index in the subscriber list
     * @param batchSize The number of subscribers to process in this batch
     * @return totalEarnings The total earnings collected from this batch
     * @return nextStartIndex The next index to start from (0 if all processed)
     * @return isComplete Whether all subscribers have been processed
     */
    function processSubscriptionsBatch(
        uint256 providerId,
        uint256 startIndex,
        uint256 batchSize
    )
        external
        onlyProvider(providerId)
        returns (uint256 totalEarnings, uint256 nextStartIndex, bool isComplete)
    {
        SubscriptionServiceStorage storage $ = _getStorage();

        {
            uint256[] memory subscriberIds = $.providerSubscribers[providerId].values();
            if (subscriberIds.length == 0 || startIndex >= subscriberIds.length) {
                emit SubscriptionsProcesses(providerId, 0);
                return (0, 0, true);
            }

            // end index calculation
            uint256 endIndex =
                startIndex + batchSize > subscriberIds.length ? subscriberIds.length : startIndex + batchSize;

            // Processing the batch
            uint256 fee = $.providers[providerId].fee;
            for (uint256 i = startIndex; i < endIndex;) {
                if (!_isValidSubscription(subscriberIds[i], providerId)) continue;
                totalEarnings += _processSubscriptionEarnings(subscriberIds[i], providerId, fee, block.timestamp);

                unchecked {
                    ++i;
                }
            }

            // state changs
            isComplete = endIndex >= subscriberIds.length;
            nextStartIndex = isComplete ? 0 : endIndex;
        }

        // Update provider balance if earnings were collected
        if (totalEarnings > 0) {
            $.providers[providerId].balance += totalEarnings;
        }

        emit SubscriptionsProcesses(providerId, totalEarnings);
    }

    function withdrawEarnings(uint256 _providerId, uint256 _amount) public onlyProvider(_providerId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        uint256 earnings = $.providers[_providerId].balance;
        if (_amount > earnings) revert InsufficientDeposit(_amount, earnings);
        $.providers[_providerId].balance = earnings - _amount;
        $.WETH.safeTransfer(_msgSender(), _amount);

        emit EarningsWithdrawn(_providerId, _amount, getUSDValueOfToken(_amount));
    }

    /**
     * @notice Increase the deposit of a subscriber
     * @param subscriberId The ID of the subscriber
     * @param depositAmt The amount of deposit in WETH
     */
    function increaseDeposit(uint256 subscriberId, uint256 depositAmt) external onlySubscriber(subscriberId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        if (!_isValidSubscriberDeposit(depositAmt)) revert InvalidSubscriberDeposit(depositAmt);
        // Transfer the funds to the contract
        $.WETH.safeTransferFrom(_msgSender(), address(this), depositAmt);

        // Update the subscriber's balance
        $.subscribers[subscriberId].totalDeposits += depositAmt;
        $.subscribers[subscriberId].currentBalance += depositAmt;

        emit DepositIncreased(subscriberId, _msgSender(), depositAmt);
    }

    /**
     * @notice Unregister a provider
     * @dev Before calling this function, the provider should process all their subscriptions and collect all their
     * earnings.
     * @param providerId The ID of the provider
     */
    function removeProvider(uint256 providerId) external onlyProvider(providerId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        address msgSender = _msgSender();

        // collect all the provider earnings
        withdrawEarnings(providerId, $.providers[providerId].balance);

        // Remove all data for the provider
        $.providerSubscribers[providerId].clear();
        delete $.providers[providerId];
        $.totalProviders--;

        emit ProviderUnregistered(providerId, msgSender);
    }

    function pauseSubscription(uint256 subscriberId, uint256 providerId) external onlySubscriber(subscriberId) {
        SubscriptionServiceStorage storage $ = _getStorage();
        $.subscriptions[subscriberId][providerId].paused = true;
        $.subscriptions[subscriberId][providerId].pausedAt = uint48(block.timestamp);
        emit SubscriptionPaused(subscriberId, providerId);
    }

    /**
     * @notice Deactivate a provider
     * @param providerId The ID of the provider
     */
    function changeProviderStatus(uint256 providerId) external onlyOwner {
        SubscriptionServiceStorage storage $ = _getStorage();
        if ($.providers[providerId].owner == address(0)) revert ProviderNotRegistered(providerId);

        bool status = $.providers[providerId].isActive;
        $.providers[providerId].isActive = !status;

        emit ProviderStatusChanged(providerId, status);
    }

    /**
     * @notice Set the price feed contract address
     * @param _priceFeed The address of the price feed contract
     */
    function setPriceFeed(address _priceFeed) external onlyOwner {
        _getStorage().priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /**
     * @notice Subscribe to a provider
     * @param providerId The ID of the provider
     * @param depositAmt The amount of deposit in WETH
     */
    function subscribe(uint256 providerId, uint256 depositAmt) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    /**
     * @notice Unsubscribe from a providerc
     * @param providerId The ID of the provider
     */
    function unsubscribe(uint256 providerId) external {
        // TODO: Implement
        revert("Not implemented yet");
    }

    function resumeSubscription(uint256 subscriberId, uint256 providerId) external {
        /**
         * 1. Validation checks
         * 2. For a particular subscription, update the billing cycle start right now and ending after
         * BILLING_PERIOD
         * 3. Add the minimum deposit amount according to the subscription and the amount is then added to the
         * provider's balance
         * 4. Remaining stays in the subscriber's balance
         */
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
     * @notice Calculate the earnings of a provider
     * @param providerId The ID of the provider
     * @return totalEarnings The total earnings of the provider
     */
    function getProviderEarnings(uint256 providerId) external view returns (uint256) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.providers[providerId].balance;
    }

    /**
     * @notice Get the total number of subscribers for a provider
     * @param providerId The ID of the provider
     * @return count The number of subscribers
     */
    function getProviderSubscriberCount(uint256 providerId) external view returns (uint256 count) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.providerSubscribers[providerId].length();
    }

    /**
     * @notice Get recommended batch size based on gas limit considerations
     * @dev This is a view function that suggests an optimal batch size
     * @return batchSize Recommended batch size for batch processing
     */
    function getRecommendedBatchSize() external pure returns (uint256 batchSize) {
        // A rough estimate, should be calculatedd based on the processing functions's
        // cost and the gas limit
        return 50;
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

    ////////////////////////////////////////////////////////
    ////////////// INTERNAL/PRIVATE FUNCTIONS //////////////
    ////////////////////////////////////////////////////////

    /**
     * @dev Process earnings for a single subscription and update state
     * @param subscriberId The ID of the subscriber
     * @param providerId The ID of the provider
     * @param providerFee The provider's fee per billing period
     * @param currentTime Current block timestamp
     * @return earnings The calculated earnings for this subscription
     */
    function _processSubscriptionEarnings(
        uint256 subscriberId,
        uint256 providerId,
        uint256 providerFee,
        uint256 currentTime
    )
        private
        returns (uint256 earnings)
    {
        SubscriptionServiceStorage storage $ = _getStorage();
        Subscription storage subscription = $.subscriptions[subscriberId][providerId];

        (uint256 calculatedEarnings, uint256 monthsPassed, uint256 userBalance) = _calculateSubscriptionEarnings(
            subscription, providerFee, currentTime, $.subscribers[subscriberId].currentBalance
        );

        // Check if user has sufficient balance and process earnings
        if (calculatedEarnings > 0) {
            if (userBalance < calculatedEarnings) {
                // Pause subscription if insufficient funds
                subscription.paused = true;
                subscription.pausedAt = uint48(currentTime);
            } else {
                // Update subscription billing period
                uint256 startTime = subscription.startTime + (monthsPassed * BILLING_PERIOD);
                subscription.startTime = uint48(startTime);
                subscription.endTime = uint48(startTime + BILLING_PERIOD);
            }

            // Deduct earnings from subscriber balance
            $.subscribers[subscriberId].currentBalance -= calculatedEarnings;
            earnings = calculatedEarnings;
        }
    }

    /**
     * @dev Calculate earnings for a single subscription
     * @param subscription The subscription to calculate earnings for
     * @param providerFee The provider's fee per billing period
     * @param currentTime Current block timestamp
     * @param userBalance Current user balance
     * @return earnings The calculated earnings for this subscription
     */
    function _calculateSubscriptionEarnings(
        Subscription storage subscription,
        uint256 providerFee,
        uint256 currentTime,
        uint256 userBalance
    )
        private
        view
        returns (uint256 earnings, uint256 monthsPassed, uint256 remainingBalance)
    {
        uint256 billingEndTime = subscription.endTime;

        // Skip if billing period hasn't ended yet
        if (currentTime < billingEndTime) return (0, 0, userBalance);

        uint256 monthsPassedLocal;

        if (subscription.paused) {
            // If paused before billing end, no earnings
            if (subscription.pausedAt < billingEndTime) {
                return (0, 0, userBalance);
            }
            // Calculate earnings up to pause time
            monthsPassedLocal = Math.ceilDiv(subscription.pausedAt - billingEndTime, BILLING_PERIOD);
        } else {
            // Calculate earnings up to current time
            monthsPassedLocal = Math.ceilDiv(currentTime - billingEndTime, BILLING_PERIOD);
        }

        if (monthsPassedLocal == 0) return (providerFee, 0, userBalance);

        // Calculate total earnings for past months
        earnings = monthsPassedLocal * providerFee;

        // Check if user has sufficient balance
        if (userBalance < earnings && monthsPassedLocal > 1) {
            uint256 affordableMonths = userBalance / providerFee;
            earnings = affordableMonths * providerFee;
            // if 2 months has passed, and we need to deduct 200 tokens, but user 170 tokens, then we deduct one month's
            // fee.
            // 200/170 * 100 = 100
        }

        return (earnings, monthsPassedLocal, remainingBalance);
    }

    function _isValidProviderFee(uint256 _fee) internal view returns (bool) {
        return getUSDValueOfToken(_fee) >= MIN_FEE;
    }

    function _isValidSubscriberDeposit(uint256 _deposit) internal view returns (bool) {
        return getUSDValueOfToken(_deposit) >= MIN_DEPOSIT;
    }

    function _generateProviderId() private returns (uint256) {
        return ++_getStorage().nextProviderId;
    }

    function _generateSubscriberId() private returns (uint256) {
        return ++_getStorage().nextSubscriberId;
    }

    function _isValidSubscription(uint256 subscriberId, uint256 providerId) private view returns (bool) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.providerSubscribers[providerId].contains(subscriberId);
    }

    function _isValidProvider(uint256 providerId) private view returns (bool) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.providers[providerId].owner != address(0);
    }

    function _isValidSubscriber(uint256 subscriberId) private view returns (bool) {
        SubscriptionServiceStorage storage $ = _getStorage();
        return $.subscribers[subscriberId].owner != address(0);
    }

    function _getStorage() private pure returns (SubscriptionServiceStorage storage $) {
        assembly {
            $.slot := SUBSCRIPTION_SERVICE_STORAGE_SLOT
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
