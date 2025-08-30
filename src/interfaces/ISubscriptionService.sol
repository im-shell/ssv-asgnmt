// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface ISubscriptionService {
    ////////////////////////
    ///// STRUCTS /////
    ////////////////////////
    struct Provider {
        address owner;
        uint256 fee;
        uint256 balance;
        bool isActive;
    }

    struct Subscriber {
        address owner;
        uint256 currentBalance;
        uint256 totalDeposits;
    }

    struct Subscription {
        uint48 startTime;
        uint48 endTime;
        uint48 pausedAt;
        bool paused;
    }

    ////////////////////////
    ///// EVENTS /////
    ////////////////////////

    event DepositIncreased(uint256 subscriberId, address owner, uint256 amount);
    event ProviderStatusChanged(uint256 providerId, bool status);
    event EarningsCollected(uint256 providerId, uint256 amount);
    event EarningsWithdrawn(uint256 providerId, uint256 amount, uint256 usdValue);
    event ProviderRegistered(uint256 providerId, address owner, uint256 fee);
    event SubscriberRegistered(uint256 subscriberId, address owner, uint256 depositAmt);
    event ProviderUnregistered(uint256 providerId, address owner);
    event SubscriberUnregistered(uint256 subscriberId, address owner);
    event Subscribed(uint256 providerId, uint256 subscriberId);
    event Unsubscribed(uint256 providerId, uint256 subscriberId);

    ////////////////////////
    ///// ERRORS /////
    ////////////////////////

    error RegistrationKeyAlreadyUsed(bytes32 key);
    error InvalidProviderFee(uint256 fee);
    error MaxProvidersReached();
    error InvalidSubscriberDeposit(uint256 deposit);
    error SubscriberAlreadyRegistered(address owner);
    error ProviderNotRegistered(uint256 providerId);
    error ProviderAlreadyRegistered(address owner);
    error InsufficientDeposit(uint256 deposit, uint256 requiredDeposit);
    error ProviderNotActive(uint256 providerId);
    error Unauthorized();

    ////////////////////////
    ///// EXTERNAL API /////
    ////////////////////////

    function registerProvider(bytes32 key, uint256 fee) external returns (uint256);
    function registerSubscriber(uint256[] memory providers, uint256 depositAmt) external returns (uint256);
    // function increaseDeposit(uint256 amt) external;
    function removeProvider(uint256 providerId) external;
    function changeProviderStatus(uint256 providerId) external;
    function subscribe(uint256 providerId, uint256 depositAmt) external;
    function unsubscribe(uint256 providerId) external;
    function collectEarnings(uint256 providerId) external;

    // Getters
    function getProviderData(uint256 providerId) external view returns (uint256, uint256, address, uint256, bool);
    function getSubscriberData(uint256 subscriberId) external view returns (address, uint256);
    function getProviderEarnings(uint256 providerId) external view returns (uint256);
    function getSubscriberDepositValueUSD(uint256 subscriberId) external view returns (uint256);
}
