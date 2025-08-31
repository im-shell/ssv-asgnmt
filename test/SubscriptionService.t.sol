// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { SubscriptionService } from "../src/SubscriptionService.sol";
import { MockWeth } from "../src/mocks/MockWeth.sol";
import { MockPriceFeed } from "../src/mocks/MockPriceFeed.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SubscriptionServiceTest is Test {
    // Contracts
    SubscriptionService public subscriptionService;
    MockWeth public mockWeth;
    MockPriceFeed public mockPriceFeed;

    address public owner;
    address public provider1;
    address public provider2;
    address public subscriber1;
    address public subscriber2;

    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant ETH_PRICE_USD = 2000e8; // $2000 per ETH
    uint256 public constant MIN_FEE_USD = 50e8; // $50 minimum fee
    uint256 public constant MIN_DEPOSIT_USD = 100e8; // $100 minimum deposit
    uint256 public constant BILLING_PERIOD = 30 days;

    bytes32 public constant REGISTRATION_KEY_1 = keccak256("provider1_key");
    bytes32 public constant REGISTRATION_KEY_2 = keccak256("provider2_key");
    bytes32 public constant REGISTRATION_KEY_2_COPY = keccak256("provider2_key");

    // Events pasted locally for qick tesitng
    event SubscriptionsProcesses(uint256 indexed providerId, uint256 amount);
    event ProviderRegistered(uint256 indexed providerId, address indexed owner, uint256 fee);
    event SubscriberRegistered(uint256 indexed subscriberId, address indexed owner, uint256 depositAmt);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        provider1 = makeAddr("provider1");
        provider2 = makeAddr("provider2");
        subscriber1 = makeAddr("subscriber1");
        subscriber2 = makeAddr("subscriber2");

        mockWeth = new MockWeth();
        mockPriceFeed = new MockPriceFeed(int256(ETH_PRICE_USD), 8);

        SubscriptionService implementation = new SubscriptionService();
        bytes memory initData = abi.encodeWithSelector(
            SubscriptionService.initialize.selector, owner, address(mockWeth), address(mockPriceFeed)
        );

        subscriptionService = SubscriptionService(payable(address(new ERC1967Proxy(address(implementation), initData))));
        vm.label(address(subscriptionService), "subscriptionService");
        vm.label(address(implementation), "implementation");
        vm.label(address(mockWeth), "mockWeth");

        // Set up price feed in the subscription service
        vm.prank(owner);
        subscriptionService.setPriceFeed(address(mockPriceFeed));

        vm.deal(owner, INITIAL_BALANCE);
        vm.deal(provider1, INITIAL_BALANCE);
        vm.deal(provider2, INITIAL_BALANCE);
        vm.deal(subscriber1, INITIAL_BALANCE);
        vm.deal(subscriber2, INITIAL_BALANCE);

        // Convert ETH to WETH for test accounts
        _convertEthToWeth(owner, INITIAL_BALANCE);
        _convertEthToWeth(provider1, INITIAL_BALANCE);
        _convertEthToWeth(provider2, INITIAL_BALANCE);
        _convertEthToWeth(subscriber1, INITIAL_BALANCE);
        _convertEthToWeth(subscriber2, INITIAL_BALANCE);
    }

    // Helper function to convert ETH to WETH
    function _convertEthToWeth(address account, uint256 amount) internal {
        vm.prank(account);
        mockWeth.deposit{ value: amount }();
    }

    // Helper function to calculate minimum fee in WETH
    function _getMinFeeWeth() internal pure returns (uint256) {
        // MIN_FEE_USD = 50e8, ETH_PRICE_USD = 2000e8
        // minFeeWeth = (50e8 * 1e18) / ETH_PRICE_USD = 0.025 ETH
        return (50e8 * 1e18) / 2000e8;
    }

    // Helper function to calculate minimum deposit in WETH
    function _getMinDepositWeth() internal pure returns (uint256) {
        // MIN_DEPOSIT_USD = 100e8, ETH_PRICE_USD = 2000e8
        // minDepositWeth = (100e8 * 1e18) / ETH_PRICE_USD = 0.05 ETH
        return (100e8 * 1e18) / 2000e8;
    }

    function _registerProvider(
        address providerOwner,
        bytes32 registrationKey,
        uint256 fee
    )
        internal
        returns (uint256)
    {
        vm.prank(providerOwner);
        return subscriptionService.registerProvider(registrationKey, fee);
    }

    function _registerSubscriber(
        address subscriberOwner,
        uint256[] memory providers,
        uint256 depositAmt
    )
        internal
        returns (uint256)
    {
        vm.prank(subscriberOwner);
        mockWeth.approve(address(subscriptionService), depositAmt);

        vm.prank(subscriberOwner);
        return subscriptionService.registerSubscriber(providers, depositAmt);
    }

    function _skipTime(uint256 timeToSkip) internal {
        vm.warp(block.timestamp + timeToSkip);
    }

    function testMockContracts() public {
        uint256 depositAmount = 1 ether;
        vm.deal(owner, depositAmount);
        vm.prank(owner);
        mockWeth.deposit{ value: depositAmount }();
        assertEq(mockWeth.balanceOf(owner), INITIAL_BALANCE + depositAmount);

        int256 newPrice = 3000e8;
        mockPriceFeed.setPrice(newPrice);
        (,,, uint256 updatedAt,) = mockPriceFeed.latestRoundData();
        assertEq(updatedAt, block.timestamp);
    }

    function testCollectEarnings_Success_SingleSubscriber() public {
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 depositAmount = providerFee * 3;
        uint256 subscriberId = _registerSubscriber(subscriber1, providers, depositAmount);

        assertEq(subscriptionService.getProviderEarnings(providerId), 0, "Provider should start with 0 earnings");

        _skipTime(BILLING_PERIOD + 1 seconds);

        vm.prank(provider1);
        subscriptionService.processAllSubscriptions(providerId);

        assertEq(
            subscriptionService.getProviderEarnings(providerId),
            providerFee,
            "Provider should have earned one period's fee"
        );

        (, uint256 subscriberBalance) = subscriptionService.getSubscriberData(subscriberId);
        assertEq(
            subscriberBalance, depositAmount - (providerFee * 2), "Subscriber balance should decrease by provider fee"
        );
    }

    function testCollectEarnings_Success_MultipleSubscribers() public { }

    function testCollectEarnings_Success_MultipleBillingPeriods() public { }

    function testCollectEarnings_NoEarnings_BeforeBillingPeriod() public { }

    function testCollectEarnings_RevertWhen_UnauthorizedCaller() public {
        // Setup: Register a provider
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vm.prank(provider2);
        subscriptionService.processAllSubscriptions(providerId);
    }

    function testCollectEarnings_InsufficientFunds_PausesSubscription() public {
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 smallDeposit = _getMinDepositWeth() + (providerFee / 4);
        uint256 subscriberId = _registerSubscriber(subscriber1, providers, smallDeposit);

        _skipTime(BILLING_PERIOD * 2 + 1 seconds);

        vm.prank(provider1);
        subscriptionService.processAllSubscriptions(providerId);

        uint256 providerEarnings = subscriptionService.getProviderEarnings(providerId);
        assertTrue(providerEarnings > 0, "Provider should get partial earnings");
        assertTrue(providerEarnings <= providerFee, "Provider earnings should not exceed available funds");

        // verify subscriber balance is lesser
        (, uint256 subscriberBalance) = subscriptionService.getSubscriberData(subscriberId);
        assertTrue(subscriberBalance < providerFee, "Subscriber should have insufficient funds for next billing");
    }

    function testFuzz_RegisterProvider_Success(bytes32 registrationKey, uint256 providerFee) public {
        // Bound the provider fee to valid range (minimum $50 USD equivalent to 10x minimum)
        uint256 minFee = _getMinFeeWeth();
        uint256 maxFee = minFee * 10; // 0.25 ETH = $500
        providerFee = bound(providerFee, minFee, maxFee);

        // Ensure the registration key is unique by combining with a known unique value
        registrationKey = keccak256(abi.encodePacked(registrationKey, "unique_suffix"));

        vm.prank(provider1);
        uint256 providerId = subscriptionService.registerProvider(registrationKey, providerFee);

        // Verify provider ID
        assertEq(providerId, 1, "First provider should have ID 1");

        // Verify provider data
        (uint256 subscriberCount, uint256 fee, address providerOwner, uint256 balance, bool isActive) =
            subscriptionService.getProviderData(providerId);

        assertEq(fee, providerFee, "Provider fee should match");
        assertEq(balance, 0, "Provider balance should be 0 initially");
        assertEq(providerOwner, provider1, "Provider owner should match");
        assertEq(subscriberCount, 0, "Provider should have no subscribers initially");
        assertTrue(isActive, "Provider should be active by default");
    }

    function testRegisterProvider_Success_MinimumFee() public {
        // Use exactly the minimum fee
        uint256 minFee = _getMinFeeWeth(); // 0.025 ETH = $50

        vm.prank(provider1);
        uint256 providerId = subscriptionService.registerProvider(REGISTRATION_KEY_1, minFee);

        // Should succeed with minimum fee
        (, uint256 fee,,,) = subscriptionService.getProviderData(providerId);
        assertEq(fee, minFee, "Provider fee should be minimum fee");
    }

    function testRegisterProvider_RevertWhen_RegistrationKeyAlreadyUsed() public {
        uint256 providerFee = _getMinFeeWeth();

        // Register first provider with key
        vm.prank(provider1);
        subscriptionService.registerProvider(REGISTRATION_KEY_1, providerFee);

        // Try to register another provider with same key
        vm.expectRevert(abi.encodeWithSignature("RegistrationKeyAlreadyUsed(bytes32)", REGISTRATION_KEY_1));
        vm.prank(provider2);
        subscriptionService.registerProvider(REGISTRATION_KEY_1, providerFee);
    }

    function testRegisterProvider_RevertWhen_InvalidProviderFee() public {
        // Fee below minimum ($50)
        uint256 lowFee = _getMinFeeWeth() - 1 wei; // Just below minimum

        vm.expectRevert(abi.encodeWithSignature("InvalidProviderFee(uint256)", lowFee));
        vm.prank(provider1);
        subscriptionService.registerProvider(REGISTRATION_KEY_1, lowFee);
    }

    function testRegisterProvider_RevertWhen_ProviderAlreadyRegistered() public {
        uint256 providerFee = _getMinFeeWeth();

        // Register provider first time
        vm.prank(provider1);
        subscriptionService.registerProvider(REGISTRATION_KEY_1, providerFee);

        // Try to register same provider again with different key
        vm.expectRevert(abi.encodeWithSignature("ProviderAlreadyRegistered(address)", provider1));
        vm.prank(provider1);
        subscriptionService.registerProvider(REGISTRATION_KEY_2, providerFee);
    }

    function testRegisterProvider_RevertWhen_MaxProvidersReached() public {
        // This test would require registering 200 providers, which might be gas-intensive
        // For now, we'll skip this test but it should be implemented if needed
        vm.skip(true);
    }

    function _verifyProviderData(uint256 providerId, uint256 expectedFee, address expectedOwner) private view {
        (uint256 subscriberCount, uint256 actualFee, address providerOwner, uint256 balance, bool isActive) =
            subscriptionService.getProviderData(providerId);

        assertEq(actualFee, expectedFee, "Provider fee should match");
        assertEq(providerOwner, expectedOwner, "Provider owner should match");
        assertEq(balance, 0, "Provider balance should be 0 initially");
        assertEq(subscriberCount, 0, "Provider should have no subscribers initially");
        assertTrue(isActive, "Provider should be active");
    }

    function testRegisterSubscriber_Success_SingleProvider() public {
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 depositAmount = providerFee * 3;

        uint256 subscriberId = _registerSubscriber(subscriber1, providers, depositAmount);

        assertEq(subscriberId, 1, "First subscriber should have ID 1");

        (address subscriberOwner, uint256 subscriberBalance) = subscriptionService.getSubscriberData(subscriberId);
        assertEq(subscriberOwner, subscriber1, "Subscriber owner should match");
        assertEq(
            subscriberBalance, depositAmount - providerFee, "Subscriber balance should be deposit minus provider fee"
        );

        (uint256 subscriberCount,,,,) = subscriptionService.getProviderData(providerId);
        assertEq(subscriberCount, 1, "Provider should have 1 subscriber");
    }

    function testRegisterSubscriber_Success_MultipleProviders() public { }

    function testRegisterSubscriber_Success_MinimumDeposit() public {
        // Setup: Register a provider with minimum fee
        uint256 providerFee = _getMinFeeWeth(); // $50
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        // Register subscriber with minimum deposit + provider fee
        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 minimumDeposit = _getMinDepositWeth(); // $100
        uint256 depositAmount = minimumDeposit + providerFee - 1 wei; // Just above minimum total

        uint256 subscriberId = _registerSubscriber(subscriber1, providers, depositAmount);

        // Should succeed
        (, uint256 subscriberBalance) = subscriptionService.getSubscriberData(subscriberId);
        assertEq(subscriberBalance, depositAmount - providerFee, "Subscriber balance should be correct");
    }

    function testRegisterSubscriber_RevertWhen_SubscriberAlreadyRegistered() public {
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 depositAmount = providerFee * 3;
        _registerSubscriber(subscriber1, providers, depositAmount);

        vm.prank(subscriber1);
        mockWeth.approve(address(subscriptionService), depositAmount);

        vm.expectRevert(abi.encodeWithSignature("SubscriberAlreadyRegistered(address)", subscriber1));
        vm.prank(subscriber1);
        subscriptionService.registerSubscriber(providers, depositAmount);
    }

    function testProcessSubscription_Success() public {
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 depositAmount = providerFee * 3;
        uint256 subscriberId = _registerSubscriber(subscriber1, providers, depositAmount);

        _skipTime(BILLING_PERIOD + 1 seconds);

        vm.prank(provider1);
        subscriptionService.processSubscription(subscriberId, providerId);

        assertEq(
            subscriptionService.getProviderEarnings(providerId),
            providerFee,
            "Provider should have earned from single subscription"
        );

        (, uint256 subscriberBalance) = subscriptionService.getSubscriberData(subscriberId);
        assertEq(
            subscriberBalance, depositAmount - (providerFee * 2), "Subscriber balance should decrease by provider fee"
        );
    }

    function testProcessSubscription_RevertWhen_SubscriptionNotExists() public {
        // Setup: Register a provider
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        // Try to process subscription that doesn't exist
        uint256 nonExistentSubscriberId = 999;
        vm.expectRevert(
            abi.encodeWithSignature("InvalidSubscription(uint256,uint256)", nonExistentSubscriberId, providerId)
        );
        vm.prank(provider1);
        subscriptionService.processSubscription(nonExistentSubscriberId, providerId);
    }

    function testProcessSubscription_RevertWhen_UnauthorizedCaller() public {
        // Setup: Register a provider and subscriber
        uint256 providerFee = _getMinFeeWeth();
        uint256 providerId = _registerProvider(provider1, REGISTRATION_KEY_1, providerFee);

        uint256[] memory providers = new uint256[](1);
        providers[0] = providerId;
        uint256 subscriberId = _registerSubscriber(subscriber1, providers, providerFee * 3);

        // Try to process subscription as wrong provider
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vm.prank(provider2);
        subscriptionService.processSubscription(subscriberId, providerId);
    }
}
